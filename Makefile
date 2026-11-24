EMACS ?= emacs

.PHONY: check compile test clean

check: compile test ## byte-compile with warnings as errors, then run tests

compile:
	$(EMACS) -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile seance.el test/seance-test.el

test:
	$(EMACS) -Q --batch -L . -l test/seance-test.el -f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc test/*.elc
