# encoding: utf-8
require 'rouge/wrappers'

class Rouge::Reader
  class UnexpectedCharacterError < StandardError; end
  class EndOfDataError < StandardError; end

  attr_accessor :ns

  @@gensym_counter = 0

  def initialize(ns, input)
    @ns = ns
    @src = input
    @n = 0
    @gensyms = []
  end

  def lex
    r =
      case peek
      when MAYBE_NUMBER
        number
      when /:/
        keyword
      when /"/
        string
      when /\(/
        Rouge::Seq::Cons[*list(')')]
      when /\[/
        list ']'
      when /#/
        dispatch
      when SYMBOL
        # SYMBOL after \[ and #, because it includes both
        symbol_or_number
      when /{/
        map
      when /'/
        quotation
      when /`/
        syntaxquotation
      when /~/
        dequotation
      when /\^/
        metadata
      when /@/
        deref
      when nil
        reader_raise EndOfDataError, "in #lex"
      else
        reader_raise UnexpectedCharacterError, "#{peek.inspect} in #lex"
      end

    r
  end

  private

  def number
    read_number(slurp(MAYBE_NUMBER))
  end

  def keyword
    begin
      slurp(/:"/)
      @n -= 1
      s = string
      s.intern
    rescue UnexpectedCharacterError
      slurp(/^:[a-zA-Z0-9\-_!\?\*\/]+/)[1..-1].intern
    end
  end

  def string
    s = ""
    t = consume
    while true
      c = @src[@n]

      if c.nil?
        reader_raise EndOfDataError, "in string, got: #{s}"
      end

      @n += 1

      if c == t
        break
      end

      if c == ?\\
        c = consume

        case c
        when nil
          reader_raise EndOfDataError, "in escaped string, got: #{s}"
        when /[abefnrstv]/
          c = {?a => ?\a,
               ?b => ?\b,
               ?e => ?\e,
               ?f => ?\f,
               ?n => ?\n,
               ?r => ?\r,
               ?s => ?\s,
               ?t => ?\t,
               ?v => ?\v}[c]
        else
          # Just leave it be.
        end
      end

      s += c
    end
    s.freeze
  end

  def list(ending)
    consume
    r = []

    while true
      if peek == ending
        break
      end
      r << lex
    end

    consume
    r.freeze
  end

  def symbol_or_number
    s = slurp(SYMBOL)
    if (s[0] == ?- or s[0] == ?+) and s[1..-1] =~ NUMBER
      read_number(s)
    else
      Rouge::Symbol[s.intern]
    end
  end

  def map
    consume
    r = {}

    while true
      if peek == '}'
        break
      end
      k = lex
      v = lex
      r[k] = v
    end

    consume
    r.freeze
  end

  def quotation
    consume
    Rouge::Seq::Cons[Rouge::Symbol[:quote], lex]
  end

  def syntaxquotation
    consume
    @gensyms.unshift(@@gensym_counter += 1)
    r = dequote(lex)
    @gensyms.shift
    r
  end

  def dequotation
    consume
    if peek == ?@
      consume
      Rouge::Splice[lex].freeze
    else
      Rouge::Dequote[lex].freeze
    end
  end

  def dequote form
    case form
    when Rouge::Seq::ISeq, Array
      rest = []
      group = []
      form.each do |f|
        if f.is_a? Rouge::Splice
          if group.length > 0
            rest << Rouge::Seq::Cons[Rouge::Symbol[:list], *group]
            group = []
          end
          rest << f.inner
        else
          group << dequote(f)
        end
      end

      if group.length > 0
        rest << Rouge::Seq::Cons[Rouge::Symbol[:list], *group]
      end

      r =
        if rest.length == 1
          rest[0]
        else
          Rouge::Seq::Cons[Rouge::Symbol[:concat], *rest]
        end

      if form.is_a?(Array)
        Rouge::Seq::Cons[Rouge::Symbol[:apply],
                    Rouge::Symbol[:vector],
                    r]
      elsif rest.length > 1
        Rouge::Seq::Cons[Rouge::Symbol[:seq], r]
      else
        r
      end
    when Hash
      Hash[form.map {|k,v| [dequote(k), dequote(v)]}]
    when Rouge::Dequote
      form.inner
    when Rouge::Symbol
      if form.ns.nil? and form.name_s =~ /(\#)$/
        Rouge::Seq::Cons[
            Rouge::Symbol[:quote],
            Rouge::Symbol[
                ("#{form.name.to_s.gsub(/(\#)$/, '')}__" \
                 "#{@gensyms[0]}__auto__").intern]]
      elsif form.ns or form.name_s =~ /^\./ or %w(& |).include? form.name_s
        Rouge::Seq::Cons[Rouge::Symbol[:quote], form]
      elsif form.ns.nil?
        begin
          var = @ns[form.name]
          Rouge::Seq::Cons[Rouge::Symbol[:quote],
                      Rouge::Symbol[:"#{var.ns}/#{var.name}"]]
        rescue Rouge::Namespace::VarNotFoundError
          Rouge::Seq::Cons[Rouge::Symbol[:quote],
                      Rouge::Symbol[:"#{@ns.name}/#{form.name}"]]
        end
      else
        raise "impossible, right?" # XXX: be bothered to ensure this is so
      end
    else
      Rouge::Seq::Cons[Rouge::Symbol[:quote], form]
    end
  end

  def regexp
    expression = ""
    terminator = '"'

    while true
      char = @src[@n]

      if char.nil?
        reader_raise EndOfDataError, "in regexp, got: #{expression}"
      end

      @n += 1

      if char == terminator
        break
      end

      if char == ?\\
        char = "\\"

        # Prevent breaking early.
        if peek == terminator
          char << consume
        end
      end

      expression << char
    end

    Regexp.new(expression).freeze
  end

  def set
    s = Set.new

    until peek == '}'
      el = lex
      s.add el
    end

    consume
    s.freeze
  end

  def dispatch
    consume
    case peek
    when '('
      body, count = dispatch_rewrite_fn(lex, 0)
      Rouge::Seq::Cons[
          Rouge::Symbol[:fn],
          (1..count).map {|n| Rouge::Symbol[:"%#{n}"]}.freeze,
          body]
    when "{"
      consume
      set
    when "'"
      consume
      Rouge::Seq::Cons[Rouge::Symbol[:var], lex]
    when "_"
      consume
      lex
      lex
    when '"'
      consume
      regexp
    else
      reader_raise UnexpectedCharacterError, "#{peek.inspect} in #dispatch"
    end
  end

  def dispatch_rewrite_fn form, count
    case form
    when Rouge::Seq::Cons, Array
      mapped = form.map do |e|
        e, count = dispatch_rewrite_fn(e, count)
        e
      end.freeze

      if form.is_a?(Rouge::Seq::Cons)
        [Rouge::Seq::Cons[*mapped], count]
      else
        [mapped, count]
      end
    when Rouge::Symbol
      if form.name == :"%"
        [Rouge::Symbol[:"%1"], [1, count].max]
      elsif form.name.to_s =~ /^%(\d+)$/
        [form, [$1.to_i, count].max]
      else
        [form, count]
      end
    else
      [form, count]
    end
  end

  def metadata
    consume
    meta = lex
    attach = lex

    if not attach.class < Rouge::Metadata
      reader_raise ArgumentError,
          "metadata can only be applied to classes mixing in Rouge::Metadata"
    end

    meta =
      case meta
      when Symbol
        {meta => true}
      when String
        {:tag => meta}
      else
        meta
      end

    extant = attach.meta
    if extant.nil?
      attach.meta = meta
    else
      attach.meta = extant.merge(meta)
    end

    attach
  end

  def deref
    consume
    Rouge::Seq::Cons[Rouge::Symbol[:"rouge.core/deref"], lex]
  end

  def slurp re
    @src[@n..-1] =~ re
    reader_raise UnexpectedCharacterError, "#{@src[@n]} in #slurp #{re}" if !$&
    @n += $&.length
    $&
  end

  def peek
    while @src[@n] =~ /[\s,;]/
      if $& == ";"
        while @src[@n] =~ /[^\n]/
          @n += 1
        end
      else
        @n += 1
      end
    end

    @src[@n]
  end

  def consume
    c = peek
    @n += 1
    c
  end

  def reader_raise ex, m
    around =
        "#{@src[[@n - 3, 0].max...[@n, 0].max]}" +
        "#{@src[@n]}" +
        "#{(@src[@n + 1..@n + 3] || "").gsub(/\n.*$/, '')}"

    line = @src[0...@n].count("\n") + 1
    char = @src[0...@n].reverse.index("\n") || 0 + 1

    raise ex,
        "around: #{around}\n" +
        "           ^\n" +
        "line #{line} char #{char}: #{m}"
  end

  def read_number s
    if NUMBER.match s
      if s =~ /[.eE]/
        Float(s)
      else
        Integer(s)
      end
    else
      reader_raise UnexpectedCharacterError, "#{s} in #read_number"
    end
  end

  # Loose expression for a possible numeric literal.
  MAYBE_NUMBER = /^[+-]?\d[\da-fA-FxX\._+-]*/

  # Ruby integer.
  INT = /\d+(?:_\d+)*/

  # Strict expression for a numeric literal.
  NUMBER = /
  ^[+-]?
  (?:
    (?:0[xX][\da-fA-F]+) (?# Hexadecimal integer)
  | (?:0[bB][01]+) (?# Binary integer)
  | (?:0\d+) (?# Octal integer)
  | (?:#{INT}(?:(?:\.#{INT})?(?:[eE][+-]?#{INT})?)?) (?# Integers and floats)
  )\z
  /ox

  SYMBOL = /^(\.\[\])|(\.?[-+]@)|([a-zA-Z0-9\-_!&\?\*\/\.\+\|=%$<>#]+)/
end

# vim: set sw=2 et cc=80:
