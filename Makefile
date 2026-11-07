EMACS ?= emacs

# Pure elisp: the journal writer is plain string work behind temp dirs,
# and the tests stub nothing heavier than the filesystem.  No -Q here,
# so a distribution's site-lisp is still found (same law as lark-org).
LOAD = -L .

SRCS = actlog.el

all: compile

compile:
	$(EMACS) --batch $(LOAD) --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(SRCS)

test:
	$(EMACS) --batch $(LOAD) -l test -f ert-run-tests-batch-and-exit

clean:
	rm -f $(SRCS:.el=.elc) test.elc

.PHONY: all compile test clean
