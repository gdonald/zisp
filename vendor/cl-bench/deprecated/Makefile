# Requires GNU Make or equivalent.

SHELL = /bin/sh

clean-results:
	-rm -f output/CL-bench*

clean: 
	find . \( -name '*.abcl' -o -name '*.cls' -o -name '*.sparcf' -o -name "*.ppcf" -o -name '*.x86f' -o -name '*.lbytef' -o -name "*.err" -o -name '*.fas' -o -name '*.fasl' -o -name "*.faslmt" -o -name '*.lib' -o -name '*.o' -o -name '*.so' -o -name "*.pfsl" -o -name "*.ufsl" -o -name "*.dfsl" -o -name "*.olisp" -o -name "*.dfsl" -o -name "*.fsl" -o -name "*.nfasl" \) -print | xargs rm -f

distclean: clean clean-results

.PHONY: clean clean-results distclean

# EOF
