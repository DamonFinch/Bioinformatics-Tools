#ifndef SEQ_CALL_H
#define SEQ_CALL_H

#include "stage.h"

namespace seq {
	class Call : public Stage {
	private:
		Func& func;
	public:
		explicit Call(Func& func);
		void codegen(llvm::Module *module) override;
		void finalize(llvm::Module *module, llvm::ExecutionEngine *eng) override;
		static Call& make(Func& func);
	};
}

#endif /* SEQ_CALL_H */