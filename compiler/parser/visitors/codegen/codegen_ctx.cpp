#include <libgen.h>
#include <memory>
#include <string>
#include <sys/stat.h>
#include <vector>

#include "lang/seq.h"
#include "parser/common.h"
#include "parser/context.h"
#include "parser/ocaml/ocaml.h"
#include "parser/visitors/codegen/codegen.h"
#include "parser/visitors/codegen/codegen_ctx.h"

using fmt::format;
using std::make_pair;

namespace seq {
namespace ast {

CodegenContext::CodegenContext(shared_ptr<Cache> cache, seq::Block *block,
                               seq::BaseFunc *base, seq::SeqJIT *jit)
    : Context<CodegenItem>(""), cache(cache), tryCatch(nullptr), jit(jit) {
  stack.push_front(vector<string>());
  topBaseIndex = topBlockIndex = 0;
  if (block)
    addBlock(block, base);
}

shared_ptr<CodegenItem> CodegenContext::find(const string &name, bool onlyLocal,
                                             bool checkStdlib) const {
  auto i = Context<CodegenItem>::find(name);
  if (i)
    return i;
  return nullptr;
}

void CodegenContext::addVar(const string &name, seq::Var *v, bool global) {
  auto i =
      make_shared<CodegenItem>(CodegenItem::Var, getBase(), global || isToplevel());
  i->handle.var = v;
  add(name, i);
}

void CodegenContext::addType(const string &name, seq::types::Type *t, bool global) {
  auto i =
      make_shared<CodegenItem>(CodegenItem::Type, getBase(), global || isToplevel());
  i->handle.type = t;
  add(name, i);
}

void CodegenContext::addFunc(const string &name, seq::BaseFunc *f, bool global) {
  auto i =
      make_shared<CodegenItem>(CodegenItem::Func, getBase(), global || isToplevel());
  i->handle.func = f;
  add(name, i);
}

void CodegenContext::addBlock(seq::Block *newBlock, seq::BaseFunc *newBase) {
  Context<CodegenItem>::addBlock();
  if (newBlock)
    topBlockIndex = blocks.size();
  blocks.push_back(newBlock);
  if (newBase)
    topBaseIndex = bases.size();
  bases.push_back(newBase);
}

void CodegenContext::popBlock() {
  bases.pop_back();
  topBaseIndex = bases.size() - 1;
  while (topBaseIndex && !bases[topBaseIndex])
    topBaseIndex--;
  blocks.pop_back();
  topBlockIndex = blocks.size() - 1;
  while (topBlockIndex && !blocks[topBlockIndex])
    topBlockIndex--;
  Context<CodegenItem>::popBlock();
}

void CodegenContext::initJIT() {
  jit = new seq::SeqJIT();
  auto fn = new seq::Func();
  fn->setName(".jit_0");

  addBlock(fn->getBlock(), fn);
  assert(topBaseIndex == topBlockIndex && topBlockIndex == 0);

  execJIT();
}

void CodegenContext::execJIT(string varName, seq::Expr *varExpr) {
  // static int counter = 0;

  // assert(jit != nullptr);
  // assert(bases.size() == 1);
  // jit->addFunc((seq::Func *)bases[0]);

  // vector<pair<string, shared_ptr<CodegenItem>>> items;
  // for (auto &name : stack.front()) {
  //   auto i = find(name);
  //   if (i && i->isGlobal())
  //     items.push_back(make_pair(name, i));
  // }
  // popBlock();
  // for (auto &i : items)
  //   add(i.first, i.second);
  // if (varExpr) {
  //   auto var = jit->addVar(varExpr);
  //   add(varName, var);
  // }

  // // Set up new block
  // auto fn = new seq::Func();
  // fn->setName(format(".jit_{}", ++counter));
  // addBlock(fn->getBlock(), fn);
  // assert(topBaseIndex == topBlockIndex && topBlockIndex == 0);
}

seq::types::Type *CodegenContext::realizeType(types::ClassType *t) {
  //  t = t->getClass();
  seqassert(t, "type must be set and a class");
  seqassert(t->canRealize(), "{} must be realizable", t->toString());
  auto it = types.find(t->realizeString());
  if (it != types.end())
    return it->second;

  seq::types::Type *handle = nullptr;
  vector<seq::types::Type *> types;
  vector<int> statics;
  for (auto &m : t->explicits)
    if (auto s = m.type->getStatic())
      statics.push_back(s->getValue());
    else
      types.push_back(realizeType(m.type->getClass().get()));
  auto name = t->name;
  if (name == ".void") {
    handle = seq::types::Void;
  } else if (name == ".bool") {
    handle = seq::types::Bool;
  } else if (name == ".byte") {
    handle = seq::types::Byte;
  } else if (name == ".int") {
    handle = seq::types::Int;
  } else if (name == ".float") {
    handle = seq::types::Float;
  } else if (name == ".str") {
    handle = seq::types::Str;
  } else if (name == ".Int" || name == ".UInt") {
    assert(statics.size() == 1 && types.size() == 0);
    assert(statics[0] >= 1 && statics[0] <= 2048);
    handle = seq::types::IntNType::get(statics[0], name == ".Int");
  } else if (name == ".Array") {
    assert(types.size() == 1 && statics.size() == 0);
    handle = seq::types::ArrayType::get(types[0]);
  } else if (name == ".Ptr") {
    assert(types.size() == 1 && statics.size() == 0);
    handle = seq::types::PtrType::get(types[0]);
  } else if (name == ".Generator") {
    assert(types.size() == 1 && statics.size() == 0);
    handle = seq::types::GenType::get(types[0]);
  } else if (name == ".Optional") {
    assert(types.size() == 1 && statics.size() == 0);
    handle = seq::types::OptionalType::get(types[0]);
  } else if (startswith(name, ".Function.")) {
    types.clear();
    for (auto &m : t->args)
      types.push_back(realizeType(m->getClass().get()));
    auto ret = types[0];
    types.erase(types.begin());
    handle = seq::types::FuncType::get(types, ret);
  } else {
    vector<string> names;
    vector<seq::types::Type *> types;
    seq::types::RecordType *record;
    if (t->isRecord()) {
      handle = record = seq::types::RecordType::get(types, names, chop(name));
    } else {
      auto cls = seq::types::RefType::get(name);
      cls->setContents(record = seq::types::RecordType::get(types, names, ""));
      // cls->setDone();
      handle = cls;
    }
    this->types[t->realizeString()] = handle;

    // Must do this afterwards to avoid infinite loop with recursive types
    for (auto &m : cache->fieldRealizations[t->realizeString()]) {
      names.push_back(m.first);
      types.push_back(realizeType(m.second->getClass().get()));
    }
    record->setContents(types, names);
  }
  return this->types[t->realizeString()] = handle;
}

} // namespace ast
} // namespace seq
