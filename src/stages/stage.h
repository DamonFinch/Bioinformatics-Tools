#ifndef SEQ_STAGES_H
#define SEQ_STAGES_H

#include <cstdint>
#include <string>
#include <map>

#include "llvm/ADT/APInt.h"
#include "llvm/IR/Verifier.h"
#include "llvm/ExecutionEngine/ExecutionEngine.h"
#include "llvm/ExecutionEngine/GenericValue.h"
#include "llvm/ExecutionEngine/MCJIT.h"
#include "llvm/ExecutionEngine/OrcMCJITReplacement.h"
#include "llvm/ExecutionEngine/SectionMemoryManager.h"
#include "llvm/IR/Argument.h"
#include "llvm/IR/BasicBlock.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/DerivedTypes.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/InstrTypes.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Type.h"
#include "llvm/Support/Casting.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Support/raw_ostream.h"

#include "../types.h"

namespace seq {
	typedef void (*SeqOp)(char *, uint32_t);
	typedef bool (*SeqPred)(char *, uint32_t);

	class Pipeline;

	enum SeqData {
		RESULT,
		IDENT,
		LEN,
		QUAL
	};

	class Stage {
	private:
		bool linked;

		types::Type in;
		types::Type out;
	protected:
		Stage *prev;
		Stage *next;
	public:
		std::string name;
		llvm::BasicBlock *block;
		std::map<SeqData, llvm::Value *> outs;

		friend Pipeline;
		Stage(std::string name, types::Type in, types::Type out);
		Stage(std::string name);
		Pipeline& operator|(Stage& to);
		Pipeline& operator|(Pipeline& to);
		std::string& getName();
		Stage *getPrev();
		Stage *getNext();

		virtual void validate();
		virtual void codegen(llvm::Module *module, llvm::LLVMContext& context);
		virtual void finalize(llvm::ExecutionEngine *eng);
	};
}

#endif /* SEQ_STAGES_H */
