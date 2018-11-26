(* 786 *)

open Core
open Err
open Ast

let foreign = Foreign.foreign

module ExprParser (S : Intf.Stmt) : Intf.Expr = 
struct
  open ExprNode

  (* ***************************************************************
     Public interface
     *************************************************************** *)

  (** [parse context expr] dispacths expression AST to the proper parser 
      and sets the position flag *)
  let rec parse (ctx: Ctx.t) (pos, node) =
    let expr = match node with
      | Empty          p -> parse_none     ctx pos p
      | Bool           p -> parse_bool     ctx pos p
      | Int            p -> parse_int      ctx pos p
      | Float          p -> parse_float    ctx pos p
      | String         p -> parse_str      ctx pos p
      | Seq            p -> parse_seq      ctx pos p
      | Generic p | Id p -> parse_id       ctx pos p
      | Tuple          p -> parse_tuple    ctx pos p
      | List           p -> parse_list     ctx pos p
      | Dict           p -> parse_dict     ctx pos p
      | Set            p -> parse_list     ctx pos p ~kind:"set"
      | ListGenerator  p -> parse_list_gen ctx pos p
      | SetGenerator   p -> parse_list_gen ctx pos p ~kind:"set"
      | DictGenerator  p -> parse_dict_gen ctx pos p
      | IfExpr         p -> parse_if       ctx pos p
      | Unary          p -> parse_unary    ctx pos p
      | Binary         p -> parse_binary   ctx pos p
      | Pipe           p -> parse_pipe     ctx pos p
      | Index          p -> parse_index    ctx pos p
      | Call           p -> parse_call     ctx pos p
      | Dot            p -> parse_dot      ctx pos p
      | Ellipsis       p -> Ctypes.null
      | Slice  _ -> serr  ~pos "slice is only valid within an index"
      | TypeOf _ -> failwith "todo: expr/typeof"
      | Lambda _ -> failwith "todo: expr/lambda"
    in
    Llvm.Expr.set_pos expr pos; 
    expr
  
  (** [parse_type context type] parses [type] AST and ensures that it is a type.
      Raises error if [type] is not type. *)
  and parse_type ctx t =
    match parse ctx t with
    | typ_expr when Llvm.Expr.is_type typ_expr ->
      Llvm.Type.expr_type typ_expr
    | _ ->
      serr ~pos:(fst t) "not a type"

  (* ***************************************************************
     Node parsers
     ***************************************************************
     Each AST node is dispatched to its parser function.
     Each parser function [f] is called as [f context position data]
     where [data] is a tuple varying from node to node. *)
  
  and parse_none _ _ _ =
    Llvm.Expr.none ()

  and parse_bool _ _ b =
    Llvm.Expr.bool b

  and parse_int _ _ i = 
    Llvm.Expr.int i

  and parse_float _ _ f = 
    Llvm.Expr.float f

  and parse_str _ _ s = 
    Llvm.Expr.str s

  and parse_seq _ _ s = 
    Llvm.Expr.seq s

  and parse_id ?map ctx pos var = 
    let map = Option.value map ~default:ctx.map in
    match Hashtbl.find map var with
    | Some (Ctx.Assignable.Var v :: _) -> 
      Llvm.Expr.var v
    | Some (Ctx.Assignable.Type t :: _) -> 
      Llvm.Expr.typ t
    | Some (Ctx.Assignable.Func t :: _) -> 
      Llvm.Expr.func t
    | Some [] | None ->
      serr ~pos "symbol '%s' not found or not realized" var

  and parse_tuple ctx _ args =
    let args = List.map args ~f:(parse ctx) in
    Llvm.Expr.tuple args

  and parse_list ?(kind="list") ctx _ args =
    let typ = get_internal_type ctx kind in
    let args = List.map args ~f:(parse ctx) in
    Llvm.Expr.list ~kind typ args

  and parse_dict ctx _ args =
    let flatten l = 
      List.fold ~init:[] ~f:(fun acc (x, y) -> y::x::acc) l |> List.rev
    in
    let typ = get_internal_type ctx "dict" in
    let args = List.map (flatten args) ~f:(parse ctx) in
    Llvm.Expr.list ~kind:"dict" typ args

  and parse_list_gen ?(kind="list") ctx _ (expr, gen) = 
    let post_process ctx fstmt = 
      let expr = parse ctx expr in
      let typ = get_internal_type ctx kind in
      Llvm.Expr.list_comprehension ~kind typ expr fstmt
    in
    comprehension_helper ctx post_process gen 

  and parse_dict_gen ctx _ (expr, gen) = 
    let post_process ctx fstmt = 
      let expr1 = parse ctx (fst expr) in
      let expr2 = parse ctx (snd expr) in
      let typ = get_internal_type ctx "dict" in
      Llvm.Expr.dict_comprehension typ expr1 expr2 fstmt
    in
    comprehension_helper ctx post_process gen 

  and parse_if ctx _  (cond, if_expr, else_expr) =
    let if_expr = parse ctx if_expr in
    let else_expr = parse ctx else_expr in
    let c_expr = parse ctx cond in
    Llvm.Expr.cond c_expr if_expr else_expr

  and parse_unary ctx _ (op, expr) =
    let expr = parse ctx expr in
    Llvm.Expr.unary op expr

  and parse_binary ctx _ (lh_expr, bop, rh_expr) =
    let lh_expr = parse ctx lh_expr in
    let rh_expr = parse ctx rh_expr in
    Llvm.Expr.binary lh_expr bop rh_expr

  and parse_pipe ctx _ exprs =
    let exprs = List.map exprs ~f:(parse ctx) in
    Llvm.Expr.pipe exprs

  and parse_index ctx pos (lh_expr, indices) =
    match snd lh_expr, indices with
    | _, [(_, Slice(st, ed, step))] ->
      if is_some step then 
        failwith "todo: expr/step";
      let unpack st = 
        Option.value_map st ~f:(parse ctx) ~default:Ctypes.null 
      in
      let lh_expr = parse ctx lh_expr in
      Llvm.Expr.slice lh_expr (unpack st) (unpack ed)
    | Id("array" | "ptr" | "generator" as name), _ ->
      if List.length indices <> 1 then
        serr ~pos "%s requires one type" name;
      let typ = parse_type ctx (List.hd_exn indices) in
      Llvm.Expr.typ @@ Llvm.Type.param ~name typ
    | Id("function"), _ ->
      let indices = List.map indices ~f:(parse_type ctx) in
      let ret, args = List.hd_exn indices, List.tl_exn indices in
      Llvm.Expr.typ @@ Llvm.Type.func ret args
    | _ -> 
      let lh_expr = parse ctx lh_expr in
      if Llvm.Expr.is_type lh_expr then
        let indices = List.map indices ~f:(parse_type ctx) in
        let typ = Llvm.Type.expr_type lh_expr in
        let typ = Llvm.Generics.Type.realize typ indices in
        Llvm.Expr.typ typ
      else if (Llvm.Expr.get_name lh_expr) = "func" then
        let indices = List.map indices ~f:(parse_type ctx) in
        let typ = Llvm.Generics.Func.realize lh_expr indices in
        Llvm.Expr.func typ
      else if (List.length indices) = 1 then
        let indices = List.map indices ~f:(parse ctx) in
        Llvm.Expr.lookup lh_expr (List.hd_exn indices)
      else
        serr ~pos "index requires only one item"
  
  and parse_call ctx pos (callee_expr, args) =
    let callee_expr = parse ctx callee_expr in
    let args = List.map args ~f:(parse ctx) in
    if Llvm.Expr.is_type callee_expr then
      let typ = Llvm.Type.expr_type callee_expr in
      Llvm.Expr.construct typ args
    else
      let kind = 
        if List.exists args ~f:((=)(Ctypes.null)) then "partial" 
        else "call" 
      in
      Llvm.Expr.call ~kind callee_expr args
    
  and parse_dot ctx pos (lh_expr, rhs) =
    let lh_expr = parse ctx lh_expr in
    if Llvm.Expr.is_type lh_expr then
      let typ = Llvm.Type.expr_type lh_expr in
      Llvm.Expr.static typ rhs 
    else
      Llvm.Expr.element lh_expr rhs
            
  (* ***************************************************************
     Helper functions
     *************************************************************** *)

  (** [comprehension_helper context finalize comprehension] 
      constructs a [for] statement for [comprehension] and passes it to 
      the finalization function [finalize context for_stmt].  *)
  and comprehension_helper ?fstmt (ctx: Ctx.t) 
      finalize (pos, {var; gen; cond; next}) = 
    let gen_expr = parse ctx gen in
    let for_stmt = Llvm.Stmt.loop gen_expr in

    Ctx.add_block ctx;
    let for_var = Llvm.Var.loop for_stmt in
    Ctx.add ctx var (Ctx.Assignable.Var for_var);

    let for_block = Llvm.Stmt.Block.loop for_stmt in
    let last_block = match cond with
      | None -> 
        for_block
      | Some expr ->
        let ctx = {ctx with block = for_block} in
        let if_expr = parse ctx expr in
        let if_stmt = Llvm.Stmt.cond () in
        let if_block = Llvm.Stmt.Block.elseif if_stmt if_expr in
        ignore @@ S.finalize_stmt ctx if_stmt pos;
        if_block
    in
    let for_stmt = Option.value ~default:for_stmt fstmt in
    let lexp = match next with
      | None -> 
        finalize ctx for_stmt 
      | Some c ->
        let ctx = { ctx with block = last_block } in
        comprehension_helper ~fstmt:for_stmt ctx finalize c
    in
    ignore @@ S.finalize_stmt ~add:(is_some fstmt) ctx for_stmt pos;
    Ctx.clear_block ctx;
    lexp

  (** Gets a [Llvm.type] from type signature. 
      Raises error if signature does not exist. *)
  and get_internal_type (ctx: Ctx.t) typ_str = 
    match Hashtbl.find ctx.map typ_str with
    | Some (Ctx.Assignable.Type (typ) :: _) -> typ
    | _ -> failwith (sprintf "can't find internal type %s" typ_str)
end