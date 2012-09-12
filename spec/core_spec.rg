;; -*- mode: clojure; -*-

(ns spec.rouge.core
  (:use rouge.test))

(testing "list"
  (testing "empty list creation"
    (is (= (list) '())))
  (testing "unary list creation"
    (is (= (list "trent") '("test"))))
  (testing "n-ary list creation"
    (is (= (apply list (range 1 51)) (.to_a (ruby/Range. 1 50))))))

; vim: set ft=clojure: