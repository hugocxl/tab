import Foundation

/// The lexical rules of the languages beyond the first C-like set.
extension Grammars {
    /// A set from space-separated words.
    static func words(_ text: String) -> Set<String> {
        Set(text.split(separator: " ").map(String.init))
    }

    private static func make(
        _ keywords: String,
        types: String = "",
        literals: String = "true false null",
        _ configure: (inout Grammar) -> Void = { _ in }
    ) -> Grammar {
        var grammar = Grammar(keywords: words(keywords), types: words(types), literals: words(literals))
        configure(&grammar)
        return grammar
    }

    private static let at: Set<UInt16> = [Ch.at]
    private static let tripleQuotes = [StringRule("\"\"\"", multiline: true)]
    private static let quotes = [StringRule("\""), StringRule("'")]
    private static let lispExtras: Set<UInt16> = Set("-?!*<>=/+&.%".utf16)

    // MARK: JVM and .NET

    static let java = make(
        """
        abstract assert break case catch class const continue default do else enum extends final finally for goto if \
        implements import instanceof interface native new package private protected public return static strictfp \
        super switch synchronized this throw throws transient try volatile while var record sealed permits yield \
        non-sealed
        """,
        types: "boolean byte char double float int long short void String Object Integer Long Double Boolean List Map Set"
    ) {
        $0.strings = [StringRule("\"\"\"", multiline: true), StringRule("\""), StringRule("'")]
        $0.attributePrefixes = at
    }

    static let kotlin = make(
        """
        as break class continue do else for fun if in interface is object package return super this throw try typealias \
        typeof val var when while by catch constructor finally get import init \
        set where abstract actual annotation companion const crossinline data enum \
        expect external final infix inline inner internal lateinit noinline open operator out override private \
        protected public reified sealed suspend tailrec vararg
        """,
        types: "Int Long Short Byte Float Double Boolean Char String Unit Any Nothing Array List Map Set"
    ) {
        $0.nestedComments = true
        $0.strings = [StringRule("\"\"\"", multiline: true), StringRule("\""), StringRule("'")]
        $0.attributePrefixes = at
    }

    static let csharp = make(
        """
        abstract as base break case catch checked class const continue default delegate do else enum event explicit \
        extern finally fixed for foreach goto if implicit in interface internal is lock namespace new operator out \
        override params private protected public readonly ref return sealed sizeof stackalloc static struct switch \
        this throw try typeof unchecked unsafe using virtual volatile while async await \
        get init let nameof partial record \
        required set var when where with yield record
        """,
        types: "bool byte char decimal double float int long object sbyte short string uint ulong ushort void nint nuint"
    ) {
        $0.strings = [
            StringRule("\"\"\"", multiline: true), StringRule("$@\"", "\"", escapes: false, multiline: true),
            StringRule("@$\"", "\"", escapes: false, multiline: true), StringRule("@\"", "\"", escapes: false, multiline: true),
            StringRule("$\"", "\""), StringRule("\""), StringRule("'"),
        ]
        $0.preprocessor = true
        $0.lineStartBrackets = true
    }

    static let fsharp = make(
        """
        abstract and as assert base begin class default delegate do done downcast downto elif else end exception \
        extern finally fixed for fun function global if in inherit inline interface internal lazy let match member \
        module mutable namespace new not of open or override private public rec return select sig static struct then \
        to try type upcast use val void when while with yield async task
        """,
        types: "int int64 uint32 float double decimal bool string char byte unit obj list seq array option"
    ) {
        $0.lineComments = ["//"]
        $0.blockComment = ("(*", "*)")
        $0.nestedComments = true
        $0.strings = [
            StringRule("\"\"\"", multiline: true), StringRule("@\"", "\"", escapes: false, multiline: true), StringRule("\""),
        ]
        $0.identifierExtras = [Ch.apostrophe]
        $0.lineStartBrackets = true
        $0.preprocessor = true
    }

    static let scala = make(
        """
        abstract case catch class def do else extends final finally for forSome if implicit import lazy match new \
        object override package private protected return sealed super this throw trait try type val var while with \
        yield given using enum export then opaque inline transparent extension
        """,
        types: "Int Long Short Byte Float Double Boolean Char String Unit Any AnyRef AnyVal Nothing Null"
    ) {
        $0.nestedComments = true
        $0.strings = [StringRule("\"\"\"", multiline: true), StringRule("\""), StringRule("'")]
        $0.attributePrefixes = at
    }

    static let groovy = make(
        """
        abstract as assert break case catch class const continue def default do else enum extends final finally for \
        goto if implements import in instanceof interface new package private protected public return static super \
        switch synchronized this threadsafe throw throws trait transient try volatile while
        """,
        types: "boolean byte char double float int long short void String Object List Map Set"
    ) {
        $0.strings = [
            StringRule("\"\"\"", multiline: true), StringRule("'''", multiline: true), StringRule("\""), StringRule("'"),
        ]
        $0.attributePrefixes = at
    }

    static let dart = make(
        """
        abstract as assert async await base break case catch class const continue covariant default deferred do \
        dynamic else enum export extends extension external factory final finally for Function get if implements \
        import in interface is late library mixin new operator required rethrow return sealed set static \
        super switch this throw try typedef var void when while with yield
        """,
        types: "int double num String bool List Map Set Object Future Stream Iterable Null Never"
    ) {
        $0.nestedComments = true
        $0.strings = [
            StringRule("\"\"\"", multiline: true), StringRule("'''", multiline: true), StringRule("r\"", "\"", escapes: false),
            StringRule("r'", "'", escapes: false), StringRule("\""), StringRule("'"),
        ]
        $0.attributePrefixes = at
    }

    // MARK: Scripting

    static let php = make(
        """
        abstract and array as break callable case catch class clone const continue declare default die do echo else \
        elseif empty enddeclare endfor endforeach endif endswitch endwhile enum eval exit extends final finally fn for \
        foreach function global goto if implements include include_once instanceof insteadof interface isset list \
        match namespace new or print private protected public readonly require require_once return static switch \
        throw trait try unset use var while xor yield php
        """,
        types: "int float string bool array mixed void callable iterable object self parent never null",
        literals: "true false null TRUE FALSE NULL"
    ) {
        $0.lineComments = ["//", "#"]
        $0.dollarVariables = true
    }

    static let lua = make(
        """
        and break do else elseif end for function goto if in local not or repeat return then until while
        """,
        literals: "true false nil"
    ) {
        $0.lineComments = ["--"]
        $0.blockComment = ("--[[", "]]")
        $0.strings = [StringRule("[[", "]]", escapes: false, multiline: true), StringRule("\""), StringRule("'")]
        $0.capitalizedTypes = false
    }

    static let perl = make(
        """
        and cmp continue default do else elsif eq exists for foreach ge given gt if last le local lt my ne next no \
        not or our package print redo require return say sub unless until use when while xor delete defined die \
        eval warn push pop shift unshift splice keys values each sort map grep join split open close printf sprintf \
        qw qq q bless ref scalar wantarray BEGIN END
        """,
        literals: "undef"
    ) {
        $0.lineComments = ["#"]
        $0.blockComment = nil
        $0.strings = [StringRule("\"", multiline: true), StringRule("'", multiline: true), StringRule("`")]
        $0.attributePrefixes = at
        $0.dollarVariables = true
        $0.hashCommentNeedsBoundary = true
        $0.capitalizedTypes = false
    }

    static let r = make(
        "if else repeat while function for in next break return library require source switch",
        literals: "TRUE FALSE NULL NA NA_integer_ NA_real_ NA_character_ Inf NaN"
    ) {
        $0.lineComments = ["#"]
        $0.blockComment = nil
        $0.identifierExtras = [Ch.dot]
        $0.capitalizedTypes = false
    }

    static let julia = make(
        """
        abstract baremodule begin break catch const continue do else elseif end export finally for function global \
        if import in isa let local macro module mutable primitive quote return struct try type using where while \
        outer
        """,
        types: "Int Int8 Int16 Int32 Int64 Int128 UInt UInt8 UInt16 UInt32 UInt64 Float16 Float32 Float64 Bool Char String Any Nothing",
        literals: "true false nothing missing Inf NaN pi"
    ) {
        $0.lineComments = ["#"]
        $0.blockComment = ("#=", "=#")
        $0.nestedComments = true
        $0.strings = [StringRule("\"\"\"", multiline: true), StringRule("\""), StringRule("'")]
        $0.attributePrefixes = at
        $0.identifierExtras = [Ch.bang]
        $0.primeSuffixes = true
    }

    static let powershell = make(
        """
        begin break catch class continue data do dynamicparam else elseif end enum exit filter finally for foreach \
        from function if in param process return switch throw trap try until using var while workflow
        """,
        literals: "true false null"
    ) {
        $0.lineComments = ["#"]
        $0.blockComment = ("<#", "#>")
        $0.strings = [
            StringRule("@\"", "\"@", escapes: false, multiline: true),
            StringRule("@'", "'@", escapes: false, multiline: true),
            StringRule("\"", escapes: false), StringRule("'", escapes: false),
        ]
        $0.attributePrefixes = [Ch.dash]
        $0.dollarVariables = true
        $0.caseInsensitive = true
        $0.identifierExtras = [Ch.dash]
        $0.cmdlets = true
        $0.capitalizedTypes = false
    }

    static let vim = make(
        """
        let unlet const set setlocal setglobal if elseif else endif for endfor while endwhile function endfunction \
        return finish call echo echom echoerr execute normal try catch finally endtry throw map nmap imap vmap \
        xmap cmap noremap nnoremap inoremap vnoremap xnoremap cnoremap command autocmd augroup end syntax highlight \
        filetype colorscheme source runtime let silent unlet plugin in break continue import export def enddef \
        vim9script
        """,
        literals: "true false v:true v:false"
    ) {
        $0.lineComments = []
        $0.blockComment = nil
        $0.leadingLineComments = ["\""]
        $0.strings = [StringRule("\""), StringRule("'", escapes: false)]
        $0.capitalizedTypes = false
    }

    static let applescript = make(
        """
        about above after against and apart around as aside at back before beginning behind below beneath beside \
        between but by considering contain contains continue copy count div does eighth else end equal equals error \
        every exit false fifth first for fourth from front get given global if ignoring in instead into is it its \
        last local me middle mod my ninth not of on onto or out over prop property put ref reference repeat returning \
        script second set seventh since sixth some tell tenth that the then third through thru timeout times to \
        transaction try until where while whose with without
        """,
        types: "application boolean class constant date integer list number real record text string window file alias",
        literals: "true false missing"
    ) {
        $0.lineComments = ["--", "#"]
        $0.blockComment = ("(*", "*)")
        $0.nestedComments = true
        $0.strings = [StringRule("\"")]
        $0.caseInsensitive = true
        $0.capitalizedTypes = false
    }

    static let bat = make(
        """
        if else not exist defined errorlevel for in do goto call set setlocal endlocal enabledelayedexpansion echo \
        exit shift pause start cd chdir md mkdir rd rmdir del copy move ren type cls title pushd popd choice \
        cmd equ neq lss leq gtr geq off on
        """,
        literals: "true false"
    ) {
        $0.lineComments = ["::"]
        $0.blockComment = nil
        $0.strings = [StringRule("\"", escapes: false)]
        $0.attributePrefixes = at
        $0.caseInsensitive = true
        $0.wordLineComments = ["rem"]
        $0.percentVariables = true
        $0.colonLabels = true
        $0.capitalizedTypes = false
    }

    static let matlab = make(
        """
        break case catch classdef continue else elseif end enumeration events for function global if methods \
        otherwise parfor persistent properties return spmd switch try while import
        """,
        literals: "true false pi Inf NaN eps"
    ) {
        $0.lineComments = ["%", "#"]
        $0.blockComment = ("%{", "%}")
        $0.strings = [StringRule("\""), StringRule("'", escapes: false)]
        $0.primeSuffixes = true
        $0.capitalizedTypes = false
    }

    static let fortran = make(
        """
        allocatable allocate assign associate backspace block call case close common contains continue cycle data \
        deallocate default do else elseif elsewhere end endblock enddo endfile endif endsubroutine endfunction \
        endmodule endprogram entry equivalence exit external format function go goto if implicit import in inout none \
        inquire intent interface intrinsic module namelist nullify only open optional out parameter pause \
        pointer print private procedure program public pure read recursive result return rewind save select \
        sequence stop subroutine target then type use where while write elemental
        """,
        types: "integer real double precision complex character logical",
        literals: "true false"
    ) {
        $0.lineComments = ["!"]
        $0.blockComment = nil
        $0.strings = [StringRule("\"", escapes: false), StringRule("'", escapes: false)]
        $0.caseInsensitive = true
        $0.capitalizedTypes = false
    }

    // MARK: Functional

    static let haskell = make(
        """
        case class data default deriving do else family forall foreign if import in infix infixl infixr instance let \
        mdo module newtype of proc qualified rec then type where as hiding
        """,
        types: "Int Integer Float Double Char String Bool Maybe Either IO Ordering Word",
        literals: "True False Nothing Just Left Right LT EQ GT"
    ) {
        $0.lineComments = ["--"]
        $0.blockComment = ("{-", "-}")
        $0.nestedComments = true
        $0.strings = [StringRule("\""), StringRule("'")]
        $0.identifierExtras = [Ch.apostrophe]
        $0.primeSuffixes = true
    }

    static let elm = make(
        """
        alias as case else exposing if import in let module of port then type where
        """,
        types: "Int Float String Bool Char List Maybe Result Cmd Sub Html Msg Model",
        literals: "True False"
    ) {
        $0.lineComments = ["--"]
        $0.blockComment = ("{-", "-}")
        $0.nestedComments = true
        $0.strings = [StringRule("\"\"\"", multiline: true), StringRule("\"")]
        $0.identifierExtras = [Ch.apostrophe]
    }

    static let ocaml = make(
        """
        and as assert begin class constraint do done downto else end exception external for fun function functor if \
        in include inherit initializer lazy let match method module mutable new nonrec object of open or private rec \
        sig struct then to try type val virtual when while with land lor lxor lsl lsr asr mod
        """,
        types: "int float string bool char unit list option array ref exn bytes",
        literals: "true false"
    ) {
        $0.lineComments = []
        $0.blockComment = ("(*", "*)")
        $0.nestedComments = true
        $0.strings = [StringRule("\"", multiline: true)]
        $0.identifierExtras = [Ch.apostrophe]
    }

    static let elixir = make(
        """
        after alias and case catch cond def defdelegate defexception defguard defimpl defmacro defmacrop defmodule \
        defp defprotocol defstruct do else end fn for if import in not or quote raise receive require rescue \
        reraise super throw try unless unquote use when with
        """,
        literals: "true false nil"
    ) {
        $0.lineComments = ["#"]
        $0.blockComment = nil
        $0.strings = [
            StringRule("\"\"\"", multiline: true), StringRule("'''", multiline: true), StringRule("\"", multiline: true),
            StringRule("'"),
        ]
        $0.rubySymbols = true
    }

    static let erlang = make(
        """
        after and andalso band begin bnot bor bsl bsr bxor case catch cond div end fun if let not of or orelse \
        receive rem try when xor
        """,
        literals: "true false undefined ok error"
    ) {
        $0.lineComments = ["%"]
        $0.blockComment = nil
        $0.leadingPrefixAttributes = [Ch.dash]
        $0.capitalizedTypes = false
    }

    static let clojure = make(
        """
        def defn defn- defmacro defmulti defmethod defprotocol defrecord deftype defonce fn let letfn loop recur if \
        if-not if-let when when-not when-let when-first cond condp case do doseq dotimes for while try catch finally \
        throw ns require import use refer in-ns new set! quote var and or not binding with-open doto -> ->> as-> \
        some-> cond-> comment declare
        """,
        literals: "true false nil"
    ) {
        $0.lineComments = [";"]
        $0.blockComment = nil
        $0.strings = [StringRule("\"", multiline: true)]
        $0.rubySymbols = true
        $0.identifierExtras = lispExtras
        $0.callsAfterOpenParen = true
        $0.capitalizedTypes = false
    }

    static let lisp = make(
        """
        and begin case cond define define-syntax define-record-type define-values defmacro defun defvar defparameter \
        defconstant defstruct defclass defmethod defgeneric defpackage in-package do dolist dotimes else flet if \
        import labels lambda let let* letrec let-values loop module not or progn provide quasiquote quote require \
        set! setf setq syntax-rules unless unquote use-package when with-slots cond-expand case-lambda delay force \
        call/cc defcustom defgroup defalias
        """,
        literals: "nil"
    ) {
        $0.lineComments = [";"]
        $0.blockComment = ("#|", "|#")
        $0.nestedComments = true
        $0.strings = [StringRule("\"", multiline: true)]
        $0.rubySymbols = true
        $0.identifierExtras = lispExtras
        $0.callsAfterOpenParen = true
        $0.capitalizedTypes = false
    }

    // MARK: Systems

    private static func intTypes(_ prefixes: String, _ sizes: String) -> String {
        prefixes.split(separator: " ").flatMap { prefix in sizes.split(separator: " ").map { "\(prefix)\($0)" } }
            .joined(separator: " ")
    }

    static let zig = make(
        """
        addrspace align allowzero and anyframe anytype asm async await break callconv catch comptime const continue \
        defer else enum errdefer error export extern fn for if inline linksection noalias nosuspend noinline opaque \
        or orelse packed pub resume return struct suspend switch test threadlocal try union unreachable usingnamespace \
        var volatile while
        """,
        types: "bool void type anyerror noreturn usize isize c_int c_uint c_long c_char f16 f32 f64 f80 f128 comptime_int comptime_float "
            + intTypes("u i", "8 16 32 64 128"),
        literals: "true false null undefined"
    ) {
        $0.blockComment = nil
        $0.attributePrefixes = at
    }

    static let nim = make(
        """
        addr and as asm bind block break case cast concept const continue converter defer discard distinct div do \
        elif else end enum except export finally for from func if import in include interface is isnot iterator \
        let macro method mixin mod nil not notin object of or out proc ptr raise ref return shl shr static template \
        try tuple type using var when while xor yield
        """,
        types: "int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 float float32 float64 string char bool seq array set Table cstring",
        literals: "true false nil"
    ) {
        $0.lineComments = ["#"]
        $0.blockComment = ("#[", "]#")
        $0.nestedComments = true
        $0.strings = [
            StringRule("\"\"\"", multiline: true), StringRule("r\"", "\"", escapes: false), StringRule("\""), StringRule("'"),
        ]
        $0.primeSuffixes = true
    }

    static let crystal = make(
        """
        abstract alias annotation as asm begin break case class def do else elsif end ensure enum extend for fun if \
        in include instance_sizeof lib macro module next of out pointerof private protected require rescue return \
        select self sizeof struct super then type typeof union uninitialized unless until verbatim when while with \
        yield
        """,
        literals: "true false nil"
    ) {
        $0.lineComments = ["#"]
        $0.blockComment = nil
        $0.strings = [StringRule("\"", multiline: true), StringRule("'"), StringRule("`")]
        $0.rubySymbols = true
    }

    static let v = make(
        """
        as asm assert atomic break const continue defer else enum fn for go goto if import in interface is \
        lock match module mut or pub return rlock select shared sizeof spawn static struct type typeof \
        union unsafe volatile __global
        """,
        types: "int i8 i16 i64 u8 u16 u32 u64 f32 f64 bool string rune byte voidptr byteptr charptr any",
        literals: "true false none"
    ) {
        $0.nestedComments = true
        $0.strings = [StringRule("r\"", "\"", escapes: false), StringRule("r'", "'", escapes: false), StringRule("\""), StringRule("'")]
        $0.attributePrefixes = at
        $0.lineStartBrackets = true
    }

    static let odin = make(
        """
        asm auto_cast bit_field bit_set break case cast context continue defer distinct do dynamic else enum \
        fallthrough for foreign if import in map matrix not_in or_break or_continue or_else or_return package proc \
        return struct switch transmute typeid union using when where
        """,
        types: "int i8 i16 i32 i64 i128 uint u8 u16 u32 u64 u128 uintptr f16 f32 f64 string cstring bool b8 b16 b32 b64 rawptr rune any typeid",
        literals: "true false nil"
    ) {
        $0.nestedComments = true
        $0.strings = [StringRule("`", escapes: false, multiline: true), StringRule("\""), StringRule("'")]
        $0.attributePrefixes = at
    }

    static let gleam = make(
        "as assert case const external fn if import let opaque panic pub todo type use auto delegate derive echo implement macro test",
        literals: "True False Nil"
    ) {
        $0.lineComments = ["//"]
        $0.blockComment = nil
        $0.strings = [StringRule("\"")]
        $0.attributePrefixes = at
    }

    static let solidity = make(
        """
        abstract anonymous as assembly break calldata catch constant constructor continue contract delete do \
        else emit enum error event external fallback for function if immutable import indexed interface internal is \
        library mapping memory modifier new override payable pragma private public pure receive return returns \
        revert require assert selfdestruct storage struct super this throw try type unchecked using var view \
        virtual while
        """,
        types: "bool string bytes address uint int byte " + intTypes("uint int", "8 16 24 32 64 128 256")
            + " " + intTypes("bytes", "1 2 4 8 16 32"),
        literals: "true false wei gwei ether seconds minutes hours days weeks"
    ) {
        $0.strings = [StringRule("hex\"", "\"", escapes: false), StringRule("\""), StringRule("'")]
    }

    static let shader: Grammar = {
        var vectors = "float half double int uint bool min16float"
        vectors += " " + intTypes("vec ivec uvec bvec dvec mat", "2 3 4")
        vectors += " " + intTypes("float int uint bool half double", "2 3 4 2x2 3x3 4x4")
        vectors += " void sampler2D sampler3D samplerCube texture2d Texture2D SamplerState Sampler sampler texture_2d f32 i32 u32 f16"
        return make(
            """
            attribute break buffer case centroid const continue default discard do else flat for highp if in inout \
            layout lowp mediump noperspective out precision return smooth struct switch uniform varying while \
            cbuffer register groupshared numthreads technique pass typedef static fn var let private storage \
            workgroup loop continuing alias enum vertex fragment kernel constant simulator thread threadgroup \
            namespace using template builtin compute
            """,
            types: vectors,
            literals: "true false"
        ) {
            $0.preprocessor = true
            $0.attributePrefixes = at
            $0.capitalizedTypes = false
        }
    }()

    // MARK: Config, data and markup

    static let graphql = make(
        """
        query mutation subscription fragment on type interface union enum input scalar schema extend directive \
        implements repeatable
        """
    ) {
        $0.lineComments = ["#"]
        $0.blockComment = nil
        $0.strings = [StringRule("\"\"\"", multiline: true), StringRule("\"")]
        $0.attributePrefixes = at
        $0.dollarVariables = true
    }

    static let protobuf = make(
        """
        syntax package import option message enum service rpc returns oneof map repeated optional required reserved \
        extend extensions stream public weak to max edition
        """,
        types: "double float int32 int64 uint32 uint64 sint32 sint64 fixed32 fixed64 sfixed32 sfixed64 bool string bytes",
        literals: "true false"
    )

    static let terraform = make(
        """
        resource data variable output locals module provider terraform required_providers backend for in if else \
        dynamic lifecycle depends_on count for_each moved import check
        """,
        literals: "true false null"
    ) {
        $0.lineComments = ["#", "//"]
        $0.leadingWordKind = .attribute
        $0.capitalizedTypes = false
    }

    static let nginx = make(
        """
        http server location upstream events if map types stream mail limit_except geo split_clients
        """,
        literals: "on off"
    ) {
        $0.lineComments = ["#"]
        $0.blockComment = nil
        $0.strings = quotes
        $0.dollarVariables = true
        $0.hashCommentNeedsBoundary = true
        $0.leadingWordKind = .keyword
        $0.capitalizedTypes = false
    }

    static let latex = make("") {
        $0.lineComments = ["%"]
        $0.blockComment = nil
        $0.strings = [StringRule("$$", multiline: true), StringRule("$")]
        $0.backslashCommands = true
        $0.capitalizedTypes = false
    }

    static let cmake = make(
        """
        if elseif else endif foreach endforeach while endwhile function endfunction macro endmacro return break \
        continue block endblock
        """,
        literals: "true false on off yes no"
    ) {
        $0.lineComments = ["#"]
        $0.blockComment = ("#[[", "]]")
        $0.strings = [StringRule("\"", multiline: true)]
        $0.dollarVariables = true
        $0.caseInsensitive = true
        $0.capitalizedTypes = false
    }

    static let nix = make(
        "let in if then else with rec inherit assert import or",
        types: "builtins",
        literals: "true false null"
    ) {
        $0.lineComments = ["#"]
        $0.strings = [StringRule("''", escapes: false, multiline: true), StringRule("\"")]
        $0.identifierExtras = [Ch.dash, Ch.apostrophe]
        $0.capitalizedTypes = false
    }

    static let prisma = make(
        "model enum datasource generator type view",
        types: "String Int Boolean DateTime Float Json BigInt Decimal Bytes",
        literals: "true false null"
    ) {
        $0.blockComment = nil
        $0.strings = [StringRule("\"")]
        $0.attributePrefixes = at
    }

    static let wat: Grammar = {
        var instructions = "block loop if else end br br_if br_table return call call_indirect drop select nop unreachable local.get local.set local.tee global.get global.set memory.size memory.grow"
        for type in ["i32", "i64", "f32", "f64"] {
            instructions += " \(type).const \(type).add \(type).sub \(type).mul \(type).load \(type).store \(type).eq \(type).ne"
        }
        instructions += " i32.div_s i32.div_u i32.rem_s i32.and i32.or i32.xor i32.shl i32.eqz i32.lt_s i32.gt_s i32.le_s i32.ge_s i32.wrap_i64 i64.extend_i32_s f64.div f64.sqrt"
        return make(
            "module func param result local global memory table export import start type data elem mut offset " + instructions,
            types: "i32 i64 f32 f64 v128 funcref externref anyfunc",
            literals: "true false"
        ) {
            $0.lineComments = [";;"]
            $0.blockComment = ("(;", ";)")
            $0.nestedComments = true
            $0.strings = [StringRule("\"")]
            $0.identifierExtras = [Ch.dot]
            $0.dollarInIdentifiers = true
            $0.capitalizedTypes = false
        }
    }()

    static let asm: Grammar = {
        let registers = """
        rax rbx rcx rdx rsi rdi rbp rsp rip eax ebx ecx edx esi edi ebp esp ax bx cx dx al bl cl dl ah bh ch dh \
        r8 r9 r10 r11 r12 r13 r14 r15 r8d r9d r10d r11d r12d r13d r14d r15d xmm0 xmm1 xmm2 xmm3 xmm4 xmm5 xmm6 xmm7 \
        cs ds es fs gs ss sp lr pc fp ip cpsr xzr wzr
        """ + " " + intTypes("r", "0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15")
            + " " + intTypes("x w v q d s", "0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30")
        return make(
            """
            mov movl movq movb movw movzx movsx movabs lea push pop call ret retq jmp je jne jz jnz jg jge jl jle ja \
            jae jb jbe js jns add addl addq sub subl subq mul imul div idiv inc dec neg not and or xor shl shr sar sal \
            rol ror cmp test nop int syscall leave hlt cld std rep movs stos lods scas cmov cmove cmovne cdq cqo xchg \
            ldr ldrb ldrh ldp str strb strh stp ldur stur b bl br blr bx beq bne bgt blt bge ble bcs bcc bmi bpl \
            cbz cbnz tbz tbnz adr adrp mvn orr eor lsl lsr asr mla mls umull smull ret svc cmn tst csel cset sxtw \
            uxtw movz movk movn fadd fsub fmul fdiv fmov vmov vadd db dw dd dq resb resw resd resq equ times section \
            global extern
            """,
            types: registers,
            literals: ""
        ) {
            $0.lineComments = [";", "//"]
            $0.blockComment = ("/*", "*/")
            $0.leadingLineComments = ["#", "@"]
            $0.strings = quotes
            $0.caseInsensitive = true
            $0.labels = true
            $0.leadingPrefixAttributes = [Ch.dot]
            $0.attributePrefixes = [Ch.dot]
            $0.identifierExtras = [Ch.dollar]
            $0.capitalizedTypes = false
        }
    }()

    /// The grammar of a language defined here.
    static func more(_ language: SyntaxLanguage) -> Grammar? {
        switch language {
        case .java: return java
        case .kotlin: return kotlin
        case .csharp: return csharp
        case .fsharp: return fsharp
        case .php: return php
        case .scala: return scala
        case .dart: return dart
        case .lua: return lua
        case .perl: return perl
        case .r: return r
        case .julia: return julia
        case .haskell: return haskell
        case .elixir: return elixir
        case .erlang: return erlang
        case .clojure: return clojure
        case .lisp: return lisp
        case .zig: return zig
        case .nim: return nim
        case .groovy: return groovy
        case .powershell: return powershell
        case .vim: return vim
        case .graphql: return graphql
        case .protobuf: return protobuf
        case .terraform: return terraform
        case .nginx: return nginx
        case .latex: return latex
        case .bat: return bat
        case .applescript: return applescript
        case .matlab: return matlab
        case .fortran: return fortran
        case .ocaml: return ocaml
        case .elm: return elm
        case .solidity: return solidity
        case .cmake: return cmake
        case .nix: return nix
        case .prisma: return prisma
        case .wat: return wat
        case .gleam: return gleam
        case .crystal: return crystal
        case .v: return v
        case .odin: return odin
        case .shader: return shader
        case .asm: return asm
        default: return nil
        }
    }
}
