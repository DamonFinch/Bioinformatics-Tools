#ifndef SEQ_EXC_H
#define SEQ_EXC_H

#include <exception>
#include "stages/stage.h"

namespace seq {
	namespace exc {
		class StageException : public std::runtime_error {
		public:
			StageException(std::string msg, Stage& stage);
		};

		class MultiLinkException : public StageException {
		public:
			explicit MultiLinkException(Stage& stage);
		};

		class ValidationException : public StageException {
		public:
			explicit ValidationException(Stage& stage);
		};

		class IOException : public std::runtime_error {
		public:
			IOException(std::string msg);
		};
	}
}

#endif /* SEQ_EXC_H */
