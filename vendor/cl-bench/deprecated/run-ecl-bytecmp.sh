#!/bin/sh

ECL=ecl

make clean optimize-files
${ECL} <<EOF
(ext:install-bytecodes-compiler)
(load "sysdep/setup-ecl.lisp")
(load "do-compilation-script.lisp")
(quit)
EOF

${ECL} <<EOF
(ext:install-bytecodes-compiler)
(load "sysdep/setup-ecl.lisp")
(load "do-execute-script.lisp")
(quit)
EOF
