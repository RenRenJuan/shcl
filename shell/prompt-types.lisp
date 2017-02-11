(defpackage :shcl/shell/prompt-types
  (:use :common-lisp :cffi-grovel)
  (:export
   #:lineinfo #:buffer #:cursor #:lastchar
   #:+el-prompt+ #:+el-rprompt+ #:+el-editor+ #:+el-bind+ #:+el-addfn+
   #:+cc-norm+ #:+cc-newline+ #:+cc-eof+ #:+cc-arghack+ #:+cc-refresh+
   #:+cc-refresh_beep+ #:+cc-cursor+ #:+cc-redisplay+ #:+cc-error+
   #:+cc-fatal+))
