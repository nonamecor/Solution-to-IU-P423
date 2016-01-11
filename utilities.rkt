#lang racket
(require racket/pretty)
(provide debug map2 label-name lookup read-fixnum make-dispatcher assert 
	 compile compile-file check-passes interp-tests compiler-tests fix while 
	 make-graph add-edge adjacent
	 general-registers registers-for-alloc caller-save callee-save
	 arg-registers register->color registers align)

(define debug-state #f)

(define (debug label val)
  (if debug-state
      (begin
	(printf "~a:\n" label)
	(pretty-print val)
	(newline))
      (void)))

(define-syntax-rule (while condition body ...)
  (let loop ()
    (when condition
      body ...
      (loop))))

(define fix (lambda (f) (lambda (x) ((f (fix f)) x))))

;; This function is like map but the function f returns
;; two values using the ``values'' form. Thus, the result
;; of map2 is two lists.
(define (map2 f ls)
  (cond [(null? ls)
         (values '() '())]
        [else
         (let-values ([(x1 x2) (f (car ls))]
                      [(ls1 ls2) (map2 f (cdr ls))])
           (values (cons x1 ls1) (cons x2 ls2)))]))

;; This function prepends an underscore to a label if
;; the current system is Mac OS and leaves it alone otherwise
(define label-name
  (lambda (n)
    (if (eqv? (system-type 'os) 'macosx)
        (string-append "_" n)
        n)))

;; The lookup function takes a key and an association list
;; and returns the corresponding value. It triggers an
;; error if the key is not present in the association list.
;;   
;; The association list may be constructed of either
;; immutable or mutable pairs.
;; 
(define lookup
  (lambda (x ls)
    (cond [(null? ls)
	   (error "lookup failed for " x)]
	  [(and (pair? (car ls)) (eq? x (car (car ls))))
	   (cdr (car ls))]
	  [(and (mpair? (car ls)) (eq? x (mcar (car ls))))
	   (mcdr (car ls))]
	  [else 
	   (lookup x (cdr ls))])))

(define (read-fixnum)
  (define r (read))
  (cond [(fixnum? r) r]
	[else (error 'read "expected an integer")]))

(define (make-dispatcher mt)
  (lambda (e . rest)
    (match e
       [`(,tag ,args ...)
	(apply (hash-ref mt tag) (append rest args))]
       [else
	(error "no match in dispatcher for " e)]
       )))

;; The check-passes function takes a compiler name (a string) and a description of
;; the passes (see below) and returns a function that takes a test name and
;; runs the passes and the appropriate interpreters to test the
;; correctness of all the passes. This function assumes there is a "tests"
;; subdirectory and a file in that directory whose name is the test name
;; followed by ".scm". Also, there should be a matching file with the
;; ending ".in" that provides the input for the Scheme program.
;;
;; The description of the passes is a list with one entry per pass.
;; An entry is a list with three things: a string giving the name of
;; the pass, the function that implements the pass (a translator from
;; AST to AST), and a function that implements the interpreter (a
;; function from AST to result value).
;;

(define (check-passes name passes)
  (lambda (test-name)
    (debug "** compiler " name)
    (debug "** checking passes for test " test-name)
    (define input-file-name (format "tests/~a.in" test-name))
    (define program-name (format "tests/~a.rkt" test-name))
    (define program-file (open-input-file program-name))
    (define sexp (read program-file))
    (close-input-port program-file)
    (debug "program:" sexp)

    (let loop ([passes passes] [p sexp] [result #f])
      (cond [(null? passes) result]
	    [else
	     (match (car passes)
		[`(,pass-name ,pass ,interp)
		 (debug "running pass" pass-name)
		 (define new-p (pass p))
		 (debug pass-name new-p)
		 (cond [interp
			(let ([new-result 
			       (if (file-exists? input-file-name)
				   (begin
				     (with-input-from-file input-file-name
				       (lambda () (interp new-p))))
				   (interp new-p))])
			  (cond [result
				 (cond [(equal? result new-result)
					(loop (cdr passes) new-p new-result)]
				       [else
					(display "in program")(newline)
					(pretty-print new-p)(newline)
					(error (format "differing results in compiler '~a' pass '~a', expected ~a, not" name pass-name result )
					       new-result)])]
				[else ;; no result to check yet
				 (loop (cdr passes) new-p new-result)]))]
		       [else
			(loop (cdr passes) new-p result)])])]))
    ))

(define (compile passes)
  (let ([prog-file-name (vector-ref (current-command-line-arguments) 0)])
    ((compile-file passes) prog-file-name)))

;; The compile-file function takes a description of the compiler
;; passes (see the comment for check-passes) and returns a function
;; that, given a program file name (a string ending in ".scm"),
;; applies all of the passes and writes the output to a file whose
;; name is the same as the proram file name but with ".scm" replaced
;; with ".s".
(define (compile-file passes)
  (lambda (prog-file-name)
    (define file-base (string-trim prog-file-name ".rkt"))
    (define prog-file (open-input-file prog-file-name))
    (define out-file-name (string-append file-base ".s"))
    (define out-file (open-output-file #:exists 'replace out-file-name))
    (define sexp (read prog-file))
    (close-input-port prog-file)
    (let ([x86 (let loop ([passes passes] [p sexp])
		 (cond [(null? passes) p]
		       [else
			(match (car passes)
			   [`(,name ,pass ,interp)
			    (let* ([new-p (pass p)])
			      (loop (cdr passes) new-p)
			      )])]))])
      (cond [(string? x86)
	     (write-string x86 out-file)
	     (newline out-file)]
	    [else
	     (error "compiler did not produce x86 output")])
      )
    (close-output-port out-file)
    ))

;; The interp-tests function takes a compiler name (a string)
;; a description of the passes (see the comment for check-passes)
;; a test family name (a string), and a list of test numbers,
;; and runs the compiler passes and the interpreters to check
;; whether the passes correct. 
;; 
;; This function assumes that the subdirectory "tests" has a bunch of
;; Scheme programs whose names all start with the family name,
;; followed by an underscore and then the test number, ending in
;; ".scm". Also, for each Scheme program there is a file with the
;; same number except that it ends with ".in" that provides the
;; input for the Scheme program.

(define (interp-tests name passes test-family test-nums)
  (define checker (check-passes name passes))
  (for ([test-name (map (lambda (n) (format "~a_~a" test-family n)) 
			test-nums)])
       (checker test-name)
       ))

;; The compiler-tests function takes a compiler name (a string) a
;; description of the passes (see the comment for check-passes) a test
;; family name (a string), and a list of test numbers (see the comment
;; for interp-tests), and runs the compiler to generate x86 (a ".s"
;; file) and then runs gcc to generate machine code.  It runs the
;; machine code and checks that the output is 42.

(define (compiler-tests name passes test-family test-nums)
  (define compiler (compile-file passes))
  (for ([test-name (map (lambda (n) (format "~a_~a" test-family n)) 
			test-nums)])
       (compiler (format "tests/~a.rkt" test-name))
       (if (system (format "gcc -g -std=c99 runtime.o tests/~a.s" test-name))
	   (void) (exit))
       (let* ([input (if (file-exists? (format "tests/~a.in" test-name))
			 (format " < tests/~a.in" test-name)
			 "")]
	      [result (system/exit-code (format "./a.out~a" input))])
	 (if (eq? result 42)
	     (begin (display test-name)(display " ")(flush-output))
	     (error (format "test ~a failed, output: ~a" 
			    test-name result))))
       ))

(define assert
  (lambda (msg b)
    (if (not b)
	(begin
	  (display "ERROR: ")
	  (display msg)
	  (newline))
	(void))))


;; System V Application Binary Interface
;; AMD64 Architecture Processor Supplement
;; Edited by Jan Hubicˇka, Andreas Jaeger, Mark Mitchell
;; December 2, 2003

(define arg-registers (vector 'rdi 'rsi 'rdx 'rcx 'r8 'r9))

(define caller-save (set 'rdx 'rcx 'rsi 'rdi 'r8 'r9 'r10 'r11 ))
(define callee-save (set 'rbx 'r12 'r13 'r14 'r15))

;; there are 13 general registers:
(define general-registers (vector 'rbx 'rcx 'rdx 'rsi 'rdi
    				  'r8 'r9 'r10 'r11 'r12 
				  'r13 'r14 'r15))

;; registers-for-alloc should always inlcude the arg-registers. -Jeremy 
(define registers-for-alloc general-registers)


(define reg-colors
  '((rax . -1) (__flag . -1)
    (rbx . 0) (rcx . 1) (rdx . 2) (rsi . 3) (rdi . 4)
    (r8 . 5) (r9 . 6) (r10 . 7) (r11 . 8) (r12 . 9) (r13 . 10)
    (r14 . 11) (r15 . 12)))

(define (register->color r)
  (cdr (assq r reg-colors)))

(define registers (set-union (list->set (vector->list general-registers))
			     (set 'rax 'rsp 'rbp '__flag)))

(define (align n alignment)
  (cond [(eq? 0 (modulo n alignment))
	 n]
	[else
	 (+ n (- alignment (modulo n alignment)))]))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Graph ADT

(define (make-graph vertices)
  (make-hash (map (lambda (v) (cons v (set))) vertices)))

(define (add-edge graph u v)
  (hash-set! graph u (set-add (hash-ref graph u (set)) v))
  (hash-set! graph v (set-add (hash-ref graph v (set)) u)))

(define (adjacent graph u)
  (hash-ref graph u))

