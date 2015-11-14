#lang racket

(require rackunit "reader.rkt")
(require rackunit/text-ui)

(require "source-pkg.rkt")

(define reader-tests
  (test-suite
   "scanner"
   (test-case
    "file must not be empty"
    (check-exn
     exn:fail?
     (lambda ()
       (read-kashmir-pkg '()))))
   
   (test-case
    "only pkg declaration is required"
    (check-equal?
     (with-input-from-string
	 "(pkg foo)"
       read-kashmir-pkg)
     (source-pkg
      '(pkg foo)
      '()
      '())))

   (test-case
    "pkg must be first top-level form"
    (check-exn
     exn:fail?
     (lambda ()
       (with-input-from-string
	 "(import fmt) (pkg main)"
	 read-kashmir-pkg))))

   (test-case
    "imports must appear before definitions"
    (check-exn
     exn:fail?
     (lambda ()
       (with-input-from-string
	 "(pkg lib) (define test 123) (import fmt)"
	 read-kashmir-pkg))))

   (let ([pkg-a (source-pkg '(pkg a) '() '())]
	 [pkg-b (source-pkg '(pkg b) '((import a)) '())]
	 [pkg-c (source-pkg '(pkg c) '((import a) (import b)) '())]
	 [pkg-d (source-pkg '(pkg d) '() '())])

     (test-case
      "source pkgs are topologically sorted by imports"
      (check-equal?
       (sort-pkgs (list pkg-c pkg-b pkg-a pkg-d))
       (list pkg-a pkg-b pkg-c pkg-d))))))

(run-tests reader-tests)