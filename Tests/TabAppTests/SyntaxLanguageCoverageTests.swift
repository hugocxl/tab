import Foundation
import XCTest
@testable import TabApp

final class SyntaxLanguageCoverageTests: XCTestCase {
    /// Highlights `source` and checks that every expected text is a token of
    /// its kind and that no token leaves the text or overlaps another.
    private func verify(
        _ language: SyntaxLanguage,
        _ source: String,
        _ expected: [TokenKind: [String]],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let text = source as NSString
        let tokens = SyntaxHighlighter.highlight(source, language: language)
        var end = 0
        for token in tokens {
            XCTAssertGreaterThanOrEqual(token.range.location, end, "\(language) tokens overlap", file: file, line: line)
            XCTAssertLessThanOrEqual(NSMaxRange(token.range), text.length, "\(language) token exceeds text", file: file, line: line)
            end = NSMaxRange(token.range)
        }
        for (kind, words) in expected {
            let found = tokens.filter { $0.kind == kind }.map { text.substring(with: $0.range) }
            for word in words {
                XCTAssertTrue(found.contains(word), "\(language): \(word) is not \(kind); \(kind) tokens: \(found)", file: file, line: line)
            }
        }
    }

    func testJava() {
        verify(.java, """
        package app;
        import java.util.List;
        /** Doc */
        @Override
        public class Main {
            // entry
            public static void main(String[] args) {
                String s = "hi";
                int n = 0xFF + 1_000;
                String t = \"\"\"
                    text block
                    \"\"\";
            }
        }
        """, [.keyword: ["package", "class", "static"], .string: ["\"hi\""], .comment: ["// entry", "/** Doc */"],
              .number: ["0xFF", "1_000"], .attribute: ["@Override"], .type: ["String", "Main"]])
    }

    func testKotlin() {
        verify(.kotlin, """
        package demo
        @Serializable
        data class User(val name: String, val age: Int)
        /* block /* nested */ done */
        fun main() {
            val text = \"\"\"
                raw
            \"\"\"
            // greet
            println("Hello world")
            val n = 42L
        }
        """, [.keyword: ["package", "data", "class", "val", "fun"], .string: ["\"Hello world\""],
              .comment: ["// greet", "/* block /* nested */ done */"], .number: ["42L"], .attribute: ["@Serializable"]])
    }

    func testCSharp() {
        verify(.csharp, """
        #region Models
        using System;
        [Serializable]
        public class Person
        {
            // name
            public string Name { get; set; } = "Ann";
            public string Path = @"C:\\dir";
            public int Age = 0x1F;
        }
        #endregion
        """, [.keyword: ["using", "public", "class", "get", "set"], .string: ["\"Ann\"", "@\"C:\\dir\""],
              .comment: ["// name"], .number: ["0x1F"], .attribute: ["[Serializable]", "#region", "#endregion"],
              .type: ["string", "Person"]])
    }

    func testFSharp() {
        verify(.fsharp, """
        module Demo
        open System
        // line
        (* block (* nested *) *)
        [<EntryPoint>]
        let main argv =
            let x = 0b1010 + 2
            let s = "hello"
            printfn "%s" s
            0
        """, [.keyword: ["module", "open", "let"], .string: ["\"hello\""], .comment: ["// line", "(* block (* nested *) *)"],
              .number: ["0b1010", "2"], .attribute: ["[<EntryPoint>]"]])
    }

    func testPHP() {
        verify(.php, """
        <?php
        namespace App;
        // line
        # hash
        /* block */
        class User extends Base {
            public function name(): string {
                $n = 'ann' . "bob";
                return $this->name ?? null;
            }
            const MAX = 1.5e3;
        }
        """, [.keyword: ["namespace", "class", "extends", "public", "function", "return"], .string: ["'ann'", "\"bob\""],
              .comment: ["// line", "# hash", "/* block */"], .number: ["1.5e3", "null"], .attribute: ["$n", "$this"]])
    }

    func testScala() {
        verify(.scala, """
        package demo
        import scala.util.Try
        // line
        @tailrec
        def fact(n: Int, acc: Long = 1L): Long =
          if (n <= 1) acc else fact(n - 1, acc * n)
        object Main extends App {
          val s = "hi"
          val doc = \"\"\"multi
            line\"\"\"
          /* done */
        }
        """, [.keyword: ["package", "import", "def", "if", "else", "object", "extends", "val"], .string: ["\"hi\"", "\"\"\"multi"],
              .comment: ["// line", "/* done */"], .number: ["1L", "1"], .attribute: ["@tailrec"], .type: ["Int", "Long", "Main"]])
    }

    func testDart() {
        verify(.dart, """
        import 'dart:io';
        // line
        /* block */
        @override
        class Counter extends Base {
          final int count = 0x10;
          String label = "n=$count";
          String doc = '''a
          b''';
          void run() async { await Future.delayed(null); }
        }
        """, [.keyword: ["import", "class", "extends", "final", "async", "await"], .string: ["'dart:io'", "\"n=$count\"", "'''a"],
              .comment: ["// line", "/* block */"], .number: ["0x10", "null"], .attribute: ["@override"], .type: ["int", "String"]])
    }

    func testLua() {
        verify(.lua, """
        -- line comment
        --[[ block
        comment ]]
        local function add(a, b)
          local s = "sum" .. 'x' .. [[long
        string]]
          if a > 0x10 and b ~= nil then return a + b * 1.5e2 end
        end
        """, [.keyword: ["local", "function", "if", "then", "return", "end", "and"], .string: ["\"sum\"", "'x'", "[[long"],
              .comment: ["-- line comment", "--[[ block", "comment ]]"], .number: ["0x10", "1.5e2", "nil"], .function: ["add"]])
    }

    func testPerl() {
        verify(.perl, """
        #!/usr/bin/perl
        use strict;
        # comment
        my $name = "world";
        my @list = (1, 2, 0x1f);
        sub greet {
            my ($who) = @_;
            print 'Hello, ' . $who . "\\n";
            return undef;
        }
        """, [.keyword: ["use", "my", "sub", "print", "return"], .string: ["\"world\"", "'Hello, '"],
              .comment: ["#!/usr/bin/perl", "# comment"], .number: ["1", "2", "0x1f", "undef"], .attribute: ["$name", "@list"]])
    }

    func testR() {
        verify(.r, """
        # comment
        library(dplyr)
        df <- data.frame(x = c(1, 2.5, 3L), y = 'a')
        f <- function(x, na.rm = TRUE) {
          if (is.na(x)) return(NULL)
          paste("val", x, 1e-3)
        }
        """, [.keyword: ["library", "function", "if", "return"], .string: ["'a'", "\"val\""], .comment: ["# comment"],
              .number: ["1", "2.5", "3L", "TRUE", "NULL", "1e-3"], .function: ["data.frame", "is.na"]])
    }

    func testJulia() {
        verify(.julia, """
        # line
        #= block #= nested =# =#
        module Demo
        function area(r::Float64)::Float64
            return pi * r^2 + 1_000 + 0x1F
        end
        s = "text"; t = \"\"\"multi
        line\"\"\"
        @time area(2.5e0)
        x = A'
        end
        """, [.keyword: ["module", "function", "return", "end"], .string: ["\"text\"", "\"\"\"multi"],
              .comment: ["# line", "#= block #= nested =# =#"], .number: ["1_000", "0x1F", "2.5e0", "pi"], .attribute: ["@time"],
              .type: ["Float64"]])
    }

    func testHaskell() {
        verify(.haskell, """
        module Main where
        import Data.List (sort)
        -- line
        {- block {- nested -} still -}
        data Shape = Circle Double | Square Double deriving (Show)
        area :: Shape -> Double
        area (Circle r) = 3.14 * r * r
        main' = putStrLn "hi" >> print (foldl' (+) 0x10 [1, 2])
        """, [.keyword: ["module", "where", "import", "data", "deriving"], .string: ["\"hi\""],
              .comment: ["-- line", "{- block {- nested -} still -}"], .number: ["3.14", "0x10"], .type: ["Shape", "Circle", "Double"]])
    }

    func testElixir() {
        verify(.elixir, """
        defmodule Greeter do
          @moduledoc \"\"\"
          Docs
          \"\"\"
          # line
          def hello(name) when is_binary(name) do
            IO.puts("Hello, #{name}" <> ~s(x))
            :ok
          end
          def n, do: 0x1F + 1_000 + nil
        end
        """, [.keyword: ["defmodule", "do", "def", "when", "end"], .string: ["\"Hello, #{name}\"", "  Docs"],
              .comment: ["# line"], .number: ["0x1F", "1_000", "nil"], .attribute: ["@moduledoc", ":ok"]])
    }

    func testErlang() {
        verify(.erlang, """
        -module(demo).
        -export([fact/1]).
        % line comment
        fact(0) -> 1;
        fact(N) when N > 0 ->
            N * fact(N - 1).
        greet() ->
            Msg = "hello",
            case X of
                ok -> 0.5e1;
                _ -> 0
            end.
        """, [.keyword: ["when", "case", "of", "end"], .string: ["\"hello\""], .comment: ["% line comment"],
              .number: ["1", "0.5e1", "ok"], .attribute: ["-module", "-export"], .function: ["fact", "greet"]])
    }

    func testClojure() {
        verify(.clojure, """
        (ns demo.core
          (:require [clojure.string :as str]))
        ; line comment
        (defn greet [name]
          (str "Hello, " name 42 3.14))
        (let [x 0x1F
              m {:a 1 :b nil}]
          (if (> x 1) true false))
        """, [.keyword: ["ns", "defn", "let", "if"], .string: ["\"Hello, \""], .comment: ["; line comment"],
              .number: ["42", "3.14", "0x1F", "nil", "true"], .attribute: [":require", ":a", ":b"], .function: ["str"]])
    }

    func testLisp() {
        verify(.lisp, """
        ;; line comment
        #| block
           comment |#
        (defun fact (n)
          "Factorial."
          (if (<= n 1) 1 (* n (fact (- n 1.5e0)))))
        (let* ((x 0) (y :key))
          (set! x 10) (display "done") nil)
        """, [.keyword: ["defun", "if", "let*", "set!"], .string: ["\"Factorial.\"", "\"done\""],
              .comment: [";; line comment", "#| block", "   comment |#"], .number: ["1", "1.5e0", "10", "nil"], .attribute: [":key"],
              .function: ["display"]])
    }

    func testZig() {
        verify(.zig, """
        const std = @import("std");
        // line
        pub fn main() !void {
            const x: u32 = 0xFF + 1_000;
            var buf: [4]u8 = undefined;
            const s = "hello";
            const c = 'a';
            if (x > 1.5e2) return;
        }
        """, [.keyword: ["const", "pub", "fn", "var", "if", "return"], .string: ["\"std\"", "\"hello\"", "'a'"], .comment: ["// line"],
              .number: ["0xFF", "1_000", "1.5e2", "undefined"], .attribute: ["@import"], .type: ["u32", "u8", "void"]])
    }

    func testNim() {
        verify(.nim, """
        # line
        #[ block
        comment ]#
        proc add(a, b: int): int =
          result = a + b + 0xFF + 5'u8
        let s = "text"
        const doc = \"\"\"raw
        more\"\"\"
        var r = r"C:\\x"
        if true: echo 1.5e3
        """, [.keyword: ["proc", "let", "const", "var", "if"], .string: ["\"text\"", "\"\"\"raw", "r\"C:\\x\""],
              .comment: ["# line", "#[ block", "comment ]#"], .number: ["0xFF", "1.5e3", "true"], .type: ["int"]])
    }

    func testGroovy() {
        verify(.groovy, """
        plugins {
            id 'java'
        }
        // line
        /* block */
        def greet(String name) {
            def text = '''multi
            line'''
            println "Hello ${name}" + 0x1F + 1.5e2
            return null
        }
        """, [.keyword: ["def", "return"], .string: ["'java'", "\"Hello ${name}\"", "'''multi"], .comment: ["// line", "/* block */"],
              .number: ["0x1F", "1.5e2", "null"], .type: ["String"]])
    }

    func testPowerShell() {
        verify(.powershell, """
        # line
        <# block
        comment #>
        function Get-Thing {
            param([string]$Name = "x")
            $items = Get-ChildItem -Path 'C:\\tmp' -Recurse
            if ($Name -eq "a" -and $items.Count -gt 0x10) { return 1.5 }
            $doc = @"
        here string
        "@
        }
        """, [.keyword: ["function", "param", "if", "return"], .string: ["\"x\"", "'C:\\tmp'", "\"a\"", "here string"],
              .comment: ["# line", "<# block", "comment #>"], .number: ["0x10", "1.5"], .attribute: ["-Path", "-eq", "$Name", "-Recurse"],
              .function: ["Get-ChildItem", "Get-Thing"]])
    }

    func testVim() {
        verify(.vim, """
        " line comment
        set number
        let g:mapleader = "\\<Space>"
        let s:count = 0x1F + 2
        function! Greet(name)
          echo 'hello ' . a:name
          if s:count > 1 | return v:true | endif
        endfunction
        nnoremap <leader>w :w<CR>
        """, [.keyword: ["set", "let", "function", "echo", "if", "return", "endif", "endfunction", "nnoremap"],
              .string: ["\"\\<Space>\"", "'hello '"], .comment: ["\" line comment"], .number: ["0x1F", "2"]])
    }

    func testIni() {
        verify(.ini, """
        ; comment
        # another
        [core]
        name = "Tab"
        port = 8080
        debug = true
        path: /usr/bin
        [remote "origin"]
            url = git@host:repo.git ; trailing
        """, [.comment: ["; comment", "# another", "; trailing"], .type: ["[core]", "[remote \"origin\"]"],
              .attribute: ["name", "port", "debug", "path", "url"], .string: ["\"Tab\""], .number: ["8080"], .keyword: ["true"]])
    }

    func testDiff() {
        verify(.diff, """
        diff --git a/a.swift b/a.swift
        index 123..456 100644
        --- a/a.swift
        +++ b/a.swift
        @@ -1,3 +1,4 @@ func main
         context
        -removed line
        +added line
        \\ No newline at end of file
        """, [.comment: ["diff --git a/a.swift b/a.swift", "index 123..456 100644", "--- a/a.swift", "+++ b/a.swift"],
              .number: ["@@ -1,3 +1,4 @@ func main"], .keyword: ["-removed line"], .string: ["+added line"]])
    }

    func testGraphQL() {
        verify(.graphql, """
        # comment
        \"\"\"Describes a user\"\"\"
        type User @key(fields: "id") {
          id: ID!
          name: String
        }
        query Q($n: Int = 10) {
          user(id: "1", limit: 2.5e1, ok: true) { ...F }
        }
        """, [.keyword: ["type", "query"], .string: ["\"\"\"Describes a user\"\"\"", "\"id\"", "\"1\""], .comment: ["# comment"],
              .number: ["10", "2.5e1", "true"], .attribute: ["@key", "$n"], .type: ["User", "ID", "String", "Int"]])
    }

    func testProtobuf() {
        verify(.protobuf, """
        syntax = "proto3";
        package demo;
        // line
        /* block */
        message User {
          string name = 1;
          repeated int32 ids = 0x2;
          optional bool on = 3;
        }
        service S { rpc Get(User) returns (User); }
        """, [.keyword: ["syntax", "package", "message", "repeated", "optional", "service", "rpc", "returns"], .string: ["\"proto3\""],
              .comment: ["// line", "/* block */"], .number: ["1", "0x2", "3"], .type: ["string", "int32", "bool", "User"]])
    }

    func testTerraform() {
        verify(.terraform, """
        # line
        // other
        /* block */
        resource "aws_instance" "web" {
          ami           = "ami-123"
          count         = 3
          monitoring    = true
          tags = { Name = "web", size = 1.5e1 }
        }
        variable "x" { default = null }
        """, [.keyword: ["resource", "variable", "count"], .string: ["\"aws_instance\"", "\"web\"", "\"ami-123\""],
              .comment: ["# line", "// other", "/* block */"], .number: ["3", "true", "1.5e1", "null"],
              .attribute: ["ami", "monitoring", "tags"]])
    }

    func testNginx() {
        verify(.nginx, """
        # comment
        worker_processes 4;
        http {
            server {
                listen 8080;
                server_name "example.com";
                gzip on;
                location / { proxy_pass http://app; set $x 1; }
            }
        }
        """, [.keyword: ["worker_processes", "http", "server", "listen", "location", "server_name", "gzip"],
              .string: ["\"example.com\""], .comment: ["# comment"], .number: ["4", "8080", "on", "1"], .attribute: ["$x"]])
    }

    func testLatex() {
        verify(.latex, """
        % comment
        \\documentclass{article}
        \\begin{document}
        Text with $x^2 + 1$ and 100\\% sure.
        \\section{Intro}
        $$ E = mc^2 $$
        \\end{document}
        """, [.keyword: ["\\documentclass", "\\begin", "\\section", "\\end"], .string: ["$x^2 + 1$", "$$ E = mc^2 $$"],
              .comment: ["% comment"], .number: ["100"]])
    }

    func testBatch() {
        verify(.bat, """
        @echo off
        REM comment
        :: other
        set NAME=world
        if "%1"=="" goto :end
        for %%i in (*.txt) do echo %%i %NAME% 42
        :end
        """, [.keyword: ["set", "if", "goto", "for", "in", "do", "echo"], .string: ["\"%1\""], .comment: ["REM comment", ":: other"],
              .number: ["42"], .attribute: ["@echo", "%%i", "%NAME%"], .function: [":end"]])
    }

    func testAppleScript() {
        verify(.applescript, """
        -- line
        # hash
        (* block (* nested *) *)
        tell application "Finder"
            set n to count of every file
            if n is greater than 0x10 then display dialog "Files: 3.5"
        end tell
        """, [.keyword: ["tell", "set", "to", "count", "of", "every", "if", "is", "then", "end"], .string: ["\"Finder\"", "\"Files: 3.5\""],
              .comment: ["-- line", "# hash", "(* block (* nested *) *)"], .number: ["0x10"], .type: ["application"]])
    }

    func testMatlab() {
        verify(.matlab, """
        % line comment
        %{
        block comment
        %}
        function y = f(x)
          s = 'it works';
          y = x' * 0x10 + 1.5e3;
          if y > pi, disp("big"); end
        end
        """, [.keyword: ["function", "if", "end"], .string: ["'it works'", "\"big\""],
              .comment: ["% line comment", "%{", "block comment", "%}"], .number: ["0x10", "1.5e3", "pi"]])
    }

    func testFortran() {
        verify(.fortran, """
        ! comment
        program demo
          implicit none
          integer :: i
          real :: x = 1.5e3
          character(len=5) :: s = 'hello'
          do i = 1, 10
            print *, "i=", i
          end do
        end program demo
        """, [.keyword: ["program", "implicit", "none", "do", "print", "end"], .string: ["'hello'", "\"i=\""], .comment: ["! comment"],
              .number: ["1.5e3", "5", "1", "10"], .type: ["integer", "real", "character"]])
    }

    func testOCaml() {
        verify(.ocaml, """
        (* comment (* nested *) done *)
        let rec fact n =
          if n <= 1 then 1 else n * fact (n - 1)
        type shape = Circle of float | Square
        let () =
          let s = "hello" in
          print_endline s; print_int 0xFF; print_float 1.5e3
        module M = struct let x' = true end
        """, [.keyword: ["let", "rec", "if", "then", "else", "type", "of", "in", "module", "struct", "end"], .string: ["\"hello\""],
              .comment: ["(* comment (* nested *) done *)"], .number: ["1", "0xFF", "1.5e3", "true"], .type: ["float", "Circle", "Square"]])
    }

    func testElm() {
        verify(.elm, """
        module Main exposing (main)
        import Html exposing (text)
        -- line
        {- block {- nested -} still -}
        type Msg = Inc | Dec
        update : Msg -> Int -> Int
        update msg model =
            case msg of
                Inc -> model + 1
        main = text "hello"
        """, [.keyword: ["module", "exposing", "import", "type", "case", "of"], .string: ["\"hello\""],
              .comment: ["-- line", "{- block {- nested -} still -}"], .number: ["1"], .type: ["Msg", "Inc", "Dec", "Int"]])
    }

    func testSolidity() {
        verify(.solidity, """
        // SPDX-License-Identifier: MIT
        pragma solidity ^0.8.0;
        /* block */
        contract Token {
            mapping(address => uint256) public balances;
            event Transfer(address indexed from, uint256 value);
            function send(uint256 amount) public returns (bool) {
                require(amount > 0x10, "bad");
                return true;
            }
        }
        """, [.keyword: ["pragma", "contract", "mapping", "public", "event", "function", "returns", "return"], .string: ["\"bad\""],
              .comment: ["// SPDX-License-Identifier: MIT", "/* block */"], .number: ["0x10", "true"], .type: ["address", "uint256", "bool"]])
    }

    func testCMake() {
        verify(.cmake, """
        cmake_minimum_required(VERSION 3.20)
        # comment
        #[[ block
        comment ]]
        project(Demo LANGUAGES CXX)
        set(SRC "main.cpp")
        if(WIN32 AND ${ENABLE} STREQUAL ON)
          add_executable(demo ${SRC})
        endif()
        """, [.keyword: ["if", "endif"], .string: ["\"main.cpp\""], .comment: ["# comment", "#[[ block", "comment ]]"],
              .number: ["3.20", "ON"], .attribute: ["${ENABLE}", "${SRC}"], .function: ["project", "set", "add_executable"]])
    }

    func testNix() {
        verify(.nix, """
        # comment
        /* block */
        { pkgs ? import <nixpkgs> {} }:
        let
          name = "demo";
          version = 1.5;
        in pkgs.mkShell {
          buildInputs = [ pkgs.nodejs ];
          shellHook = ''
            echo hi
          '';
          enable = true;
        }
        """, [.keyword: ["import", "let", "in"], .string: ["\"demo\"", "''", "    echo hi", "  ''"],
              .comment: ["# comment", "/* block */"], .number: ["1.5", "true"]])
    }

    func testPrisma() {
        verify(.prisma, """
        // comment
        datasource db {
          provider = "postgresql"
        }
        model User {
          id    Int     @id @default(autoincrement())
          email String  @unique
          admin Boolean @default(false)
          score Float   @default(1.5)
        }
        """, [.keyword: ["datasource", "model"], .string: ["\"postgresql\""], .comment: ["// comment"], .number: ["false", "1.5"],
              .attribute: ["@id", "@default", "@unique"], .type: ["Int", "String", "Boolean", "Float", "User"]])
    }

    func testWat() {
        verify(.wat, """
        ;; line comment
        (; block (; nested ;) ;)
        (module
          (import "env" "log" (func $log (param i32)))
          (func $add (param $a i32) (result i32)
            local.get $a
            i32.const 0x10
            i32.add)
          (export "add" (func $add)))
        """, [.keyword: ["module", "import", "func", "param", "result", "local.get", "i32.const", "i32.add", "export"],
              .string: ["\"env\"", "\"log\"", "\"add\""], .comment: [";; line comment", "(; block (; nested ;) ;)"],
              .number: ["0x10"], .type: ["i32"]])
    }

    func testGleam() {
        verify(.gleam, """
        import gleam/io
        // line
        @external(erlang, "a", "b")
        pub fn main() {
          let x = 0xFF + 1_000
          let s = "hello"
          case x { 1 -> io.println(s) _ -> Nil }
        }
        pub type Shape { Circle(Float) }
        """, [.keyword: ["import", "pub", "fn", "let", "case", "type"], .string: ["\"hello\""], .comment: ["// line"],
              .number: ["0xFF", "1_000", "1", "Nil"], .attribute: ["@external"], .type: ["Shape", "Float"]])
    }

    func testCrystal() {
        verify(.crystal, """
        # line
        require "json"
        class Person
          property name : String
          def initialize(@name : String); end
          def greet
            puts "Hi #{@name}" if name != nil
            x = 0xFF + 1_000 + :sym.to_s.size
          end
        end
        """, [.keyword: ["require", "class", "def", "end", "if"], .string: ["\"json\"", "\"Hi #{@name}\""], .comment: ["# line"],
              .number: ["nil", "0xFF", "1_000"], .attribute: [":sym", "@name"], .type: ["Person", "String"]])
    }

    func testV() {
        verify(.v, """
        module main
        import os
        // line
        /* block */
        [inline]
        fn add(a int, b int) int {
            s := 'hello'
            return a + b + 0xFF + 1_000
        }
        struct User { name string }
        """, [.keyword: ["module", "import", "fn", "return", "struct"], .string: ["'hello'"], .comment: ["// line", "/* block */"],
              .number: ["0xFF", "1_000"], .attribute: ["[inline]"], .type: ["int", "string", "User"]])
    }

    func testOdin() {
        verify(.odin, """
        package main
        import "core:fmt"
        // line
        /* block */
        @(private)
        main :: proc() {
            x: int = 0xFF + 1_000
            fmt.println("hello", `raw`)
            if x > 1.5e2 { return }
        }
        """, [.keyword: ["package", "import", "proc", "if", "return"], .string: ["\"core:fmt\"", "\"hello\"", "`raw`"],
              .comment: ["// line", "/* block */"], .number: ["0xFF", "1_000", "1.5e2"], .type: ["int"]])
    }

    func testShader() {
        verify(.shader, """
        #version 450
        // line
        /* block */
        layout(location = 0) in vec3 position;
        uniform mat4 mvp;
        struct Light { float4 color; };
        void main() {
            vec4 p = mvp * vec4(position, 1.0);
            if (p.x > 0x10) discard;
        }
        """, [.keyword: ["layout", "in", "uniform", "struct", "if", "discard"], .comment: ["// line", "/* block */"],
              .number: ["1.0", "0x10"], .attribute: ["#version"], .type: ["vec3", "mat4", "float4", "vec4", "void"]])
    }

    func testAsm() {
        verify(.asm, """
        ; comment
        # hash comment
        section .text
        .globl main
        main:
            mov rax, 0x10
            add rax, 42 ; trailing
            ldr x0, [sp, #8]
            call puts
            ret
        msg: db "hello", 0
        """, [.keyword: ["section", "mov", "add", "ldr", "call", "ret", "db"], .string: ["\"hello\""],
              .comment: ["; comment", "# hash comment", "; trailing"], .number: ["0x10", "42", "8"], .attribute: [".globl"],
              .type: ["rax", "x0", "sp"], .function: ["main", "msg"]])
    }

    func testLog() {
        verify(.log, """
        2024-01-02T10:11:12.345Z INFO server started on port 8080
        10:11:13 WARN disk at 91%
        10:11:14 ERROR failed to open "file.txt" (code 2)
        """, [.number: ["2024-01-02T10:11:12.345Z", "8080", "10:11:13", "2"], .comment: ["INFO"], .attribute: ["WARN"],
              .keyword: ["ERROR"], .string: ["\"file.txt\""]])
    }

    func testHTTP() {
        verify(.http, """
        ### create
        POST /api/users?id=1 HTTP/1.1
        Host: example.com
        Content-Length: 24
        Content-Type: application/json

        {"name": "ann", "age": 30, "ok": true}
        """, [.keyword: ["POST", "true"], .string: ["/api/users?id=1", "example.com", "application/json", "\"ann\""],
              .type: ["HTTP/1.1"], .attribute: ["Host", "Content-Length", "Content-Type"], .number: ["24", "30"],
              .comment: ["### create"]])
        verify(.http, "HTTP/1.1 404 Not Found\nServer: nginx", [.type: ["HTTP/1.1"], .number: ["404"], .attribute: ["Server"]])
    }

    func testPropertiesBangComments() {
        verify(.ini, "! properties comment\nkey=value\n", [.comment: ["! properties comment"], .attribute: ["key"]])
    }

    func testLuaBlockCommentCarriesAcrossLines() {
        let tokens = SyntaxHighlighter.highlight("--[[ open\nstill\n]] x = 1", language: .lua)
        XCTAssertEqual(tokens.first?.kind, .comment)
        XCTAssertTrue(tokens.contains { $0.kind == .number })
    }

    // MARK: Fence info strings and file names

    func testFenceAliases() {
        let table: [SyntaxLanguage: [String]] = [
            .javaScript: ["js", "javascript", "mjs", "cjs"], .typeScript: ["ts", "typescript"],
            .shell: ["sh", "shell", "bash", "zsh", "fish", "console", "shellsession"], .yaml: ["yml", "yaml"],
            .objectiveC: ["objc", "objective-c", "objectivec"], .cpp: ["c++", "cpp", "cc", "cxx"],
            .csharp: ["c#", "cs", "csharp"], .fsharp: ["f#", "fsharp"], .python: ["py", "python", "python3"],
            .ruby: ["rb", "ruby"], .rust: ["rs", "rust"], .go: ["golang", "go"], .kotlin: ["kt", "kotlin", "kts"],
            .dockerfile: ["docker", "dockerfile"], .makefile: ["make", "makefile"], .markdown: ["md", "markdown", "mdx"],
            .html: ["html", "htm", "xhtml", "vue", "svelte", "astro"], .xml: ["xml", "plist", "svg"],
            .css: ["css", "scss", "sass", "less", "postcss"],
            .sql: ["sql", "mysql", "postgres", "postgresql", "psql", "sqlite", "plsql"],
            .json: ["json", "jsonc", "json5", "jsonl"], .toml: ["toml"],
            .ini: ["ini", "cfg", "conf", "properties", "editorconfig", "gitconfig"], .diff: ["diff", "patch"],
            .graphql: ["graphql", "gql"], .protobuf: ["proto", "protobuf"], .terraform: ["tf", "terraform", "hcl"],
            .latex: ["tex", "latex"], .powershell: ["ps1", "powershell", "pwsh"], .bat: ["bat", "cmd"],
            .vim: ["vim", "viml"], .haskell: ["hs", "haskell"], .elixir: ["ex", "exs", "elixir"],
            .erlang: ["erl", "erlang"], .clojure: ["clj", "cljs", "clojure", "edn"],
            .lisp: ["lisp", "scheme", "racket", "el", "emacs-lisp"], .lua: ["lua"], .perl: ["pl", "perl"], .r: ["r"],
            .julia: ["jl", "julia"], .dart: ["dart"], .scala: ["scala", "sbt"], .groovy: ["groovy", "gradle"],
            .zig: ["zig"], .nim: ["nim"], .php: ["php"], .java: ["java"], .nginx: ["nginx"],
            .applescript: ["applescript"], .matlab: ["matlab", "octave"], .fortran: ["f90", "fortran"],
            .ocaml: ["ml", "ocaml"], .elm: ["elm"], .solidity: ["sol", "solidity"], .cmake: ["cmake"], .nix: ["nix"],
            .prisma: ["prisma"], .wat: ["wat", "wasm"], .gleam: ["gleam"], .crystal: ["cr", "crystal"],
            .v: ["v", "vlang"], .odin: ["odin"], .shader: ["glsl", "hlsl", "wgsl", "metal", "shader"],
            .asm: ["asm", "nasm", "s", "x86asm", "arm"], .log: ["log"], .http: ["http"],
            .plain: ["txt", "text", "plain", "plaintext"],
        ]
        for (language, aliases) in table {
            for alias in aliases {
                XCTAssertEqual(SyntaxLanguage.forFence(alias), language, alias)
                XCTAssertEqual(SyntaxLanguage.forFence(alias.uppercased()), language, alias)
            }
        }
    }

    func testFenceInfoStringsUseTheFirstWord() {
        XCTAssertEqual(SyntaxLanguage.forFence("ts title=\"x\""), .typeScript)
        XCTAssertEqual(SyntaxLanguage.forFence("  Python  {1,3}"), .python)
        XCTAssertEqual(SyntaxLanguage.forFence("rust,no_run"), .rust)
        XCTAssertEqual(SyntaxLanguage.forFence("language-bash"), .shell)
        XCTAssertEqual(SyntaxLanguage.forFence("yaml\tfile.yml"), .yaml)
    }

    func testUnknownFenceResolvesToPlain() {
        XCTAssertEqual(SyntaxLanguage.forFence(""), .plain)
        XCTAssertEqual(SyntaxLanguage.forFence("   "), .plain)
        XCTAssertEqual(SyntaxLanguage.forFence("klingon"), .plain)
        XCTAssertEqual(SyntaxLanguage.forFence("title=\"x\""), .plain)
    }

    func testDetectsNewExtensions() {
        let table: [String: SyntaxLanguage] = [
            "A.java": .java, "a.kt": .kotlin, "a.kts": .kotlin, "A.cs": .csharp, "a.fs": .fsharp, "a.php": .php,
            "a.scala": .scala, "a.sbt": .scala, "a.dart": .dart, "a.lua": .lua, "a.pl": .perl, "a.R": .r, "a.jl": .julia,
            "a.hs": .haskell, "a.ex": .elixir, "a.exs": .elixir, "a.erl": .erlang, "a.clj": .clojure, "a.lisp": .lisp,
            "a.rkt": .lisp, "a.el": .lisp, "a.zig": .zig, "a.nim": .nim, "a.groovy": .groovy, "a.gradle": .groovy,
            "a.ps1": .powershell, "a.vim": .vim, ".vimrc": .vim, "a.ini": .ini, ".editorconfig": .ini,
            ".gitconfig": .ini, "a.properties": .ini, "a.diff": .diff, "a.patch": .diff, "a.graphql": .graphql,
            "a.proto": .protobuf, "main.tf": .terraform, "a.hcl": .terraform, "nginx.conf": .nginx, "a.tex": .latex,
            "a.bat": .bat, "a.cmd": .bat, "a.applescript": .applescript, "a.f90": .fortran, "a.ml": .ocaml,
            "a.elm": .elm, "a.sol": .solidity, "CMakeLists.txt": .cmake, "a.cmake": .cmake, "a.nix": .nix,
            "schema.prisma": .prisma, "a.wat": .wat, "a.gleam": .gleam, "a.cr": .crystal, "a.v": .v, "a.odin": .odin,
            "a.glsl": .shader, "a.hlsl": .shader, "a.wgsl": .shader, "a.metal": .shader, "a.asm": .asm, "a.S": .asm,
            "a.log": .log, "a.http": .http, "a.astro": .html, "a.jsonl": .json, "a.csv": .plain, "a.tsv": .plain,
            "Jenkinsfile": .groovy,
        ]
        for (name, language) in table {
            XCTAssertEqual(SyntaxLanguage.detect(fileName: name), language, name)
        }
    }

    func testEveryLanguageHighlightsArbitraryTextWithoutInvalidRanges() {
        let source = "x = \"unterminated\n/* open\n'q' 0x1F 1.5e3 @a $b %c #d ;e \\f {{ [[ <<\n}} ]] -- -->\n"
        let length = (source as NSString).length
        for language in SyntaxLanguage.allCases {
            var end = 0
            for token in SyntaxHighlighter.highlight(source, language: language) {
                XCTAssertGreaterThanOrEqual(token.range.location, end, "\(language)")
                XCTAssertLessThanOrEqual(NSMaxRange(token.range), length, "\(language)")
                XCTAssertGreaterThan(token.range.length, 0, "\(language)")
                end = NSMaxRange(token.range)
            }
        }
    }
}
