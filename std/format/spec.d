// Written in the D programming language.

/**
   This is a submodule of $(MREF std, format).
   It provides some helpful tools.

   Copyright: Copyright The D Language Foundation 2000-2013.

   License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0).

   Authors: $(HTTP walterbright.com, Walter Bright), $(HTTP erdani.com,
   Andrei Alexandrescu), and Kenji Hara

   Source: $(PHOBOSSRC std/format/spec.d)
 */
module std.format.spec;

import std.traits : Unqual;
import std.format;

template FormatSpec(Char)
if (!is(Unqual!Char == Char))
{
    alias FormatSpec = FormatSpec!(Unqual!Char);
}

/**
 * A General handler for `printf` style format specifiers. Used for building more
 * specific formatting functions.
 */
struct FormatSpec(Char)
if (is(Unqual!Char == Char))
{
    import std.algorithm.searching : startsWith;
    import std.ascii : isDigit;
    import std.conv : parse, text, to;
    import std.range.primitives;

    /**
       Minimum _width, default `0`.
     */
    int width = 0;

    /**
       Precision. Its semantics depends on the argument type. For
       floating point numbers, _precision dictates the number of
       decimals printed.
     */
    int precision = UNSPECIFIED;

    /**
       Number of digits printed between _separators.
    */
    int separators = UNSPECIFIED;

    /**
       Set to `DYNAMIC` when the separator character is supplied at runtime.
    */
    int separatorCharPos = UNSPECIFIED;

    /**
       Character to insert between digits.
    */
    dchar separatorChar = ',';

    /**
       Special value for width and precision. `DYNAMIC` width or
       precision means that they were specified with `'*'` in the
       format string and are passed at runtime through the varargs.
     */
    enum int DYNAMIC = int.max;

    /**
       Special value for precision, meaning the format specifier
       contained no explicit precision.
     */
    enum int UNSPECIFIED = DYNAMIC - 1;

    /**
       The actual format specifier, `'s'` by default.
    */
    char spec = 's';

    /**
       Index of the argument for positional parameters, from `1` to
       `ubyte.max`. (`0` means not used).
    */
    ubyte indexStart;

    /**
       Index of the last argument for positional parameter range, from
       `1` to `ubyte.max`. (`0` means not used).
    */
    ubyte indexEnd;

    version (StdDdoc)
    {
        /**
         The format specifier contained a `'-'` (`printf`
         compatibility).
         */
        bool flDash;

        /**
         The format specifier contained a `'0'` (`printf`
         compatibility).
         */
        bool flZero;

        /**
         The format specifier contained a $(D ' ') (`printf`
         compatibility).
         */
        bool flSpace;

        /**
         The format specifier contained a `'+'` (`printf`
         compatibility).
         */
        bool flPlus;

        /**
         The format specifier contained a `'#'` (`printf`
         compatibility).
         */
        bool flHash;

        /**
         The format specifier contained a `','`
         */
        bool flSeparator;

        // Fake field to allow compilation
        ubyte allFlags;
    }
    else
    {
        union
        {
            import std.bitmanip : bitfields;
            mixin(bitfields!(
                        bool, "flDash", 1,
                        bool, "flZero", 1,
                        bool, "flSpace", 1,
                        bool, "flPlus", 1,
                        bool, "flHash", 1,
                        bool, "flSeparator", 1,
                        ubyte, "", 2));
            ubyte allFlags;
        }
    }

    /**
       In case of a compound format specifier starting with $(D
       "%$(LPAREN)") and ending with `"%$(RPAREN)"`, `_nested`
       contains the string contained within the two separators.
     */
    const(Char)[] nested;

    /**
       In case of a compound format specifier, `_sep` contains the
       string positioning after `"%|"`.
       `sep is null` means no separator else `sep.empty` means 0 length
        separator.
     */
    const(Char)[] sep;

    /**
       `_trailing` contains the rest of the format string.
     */
    const(Char)[] trailing;

    /*
       This string is inserted before each sequence (e.g. array)
       formatted (by default `"["`).
     */
    enum immutable(Char)[] seqBefore = "[";

    /*
       This string is inserted after each sequence formatted (by
       default `"]"`).
     */
    enum immutable(Char)[] seqAfter = "]";

    /*
       This string is inserted after each element keys of a sequence (by
       default `":"`).
     */
    enum immutable(Char)[] keySeparator = ":";

    /*
       This string is inserted in between elements of a sequence (by
       default $(D ", ")).
     */
    enum immutable(Char)[] seqSeparator = ", ";

    /**
       Construct a new `FormatSpec` using the format string `fmt`, no
       processing is done until needed.
     */
    this(in Char[] fmt) @safe pure
    {
        trailing = fmt;
    }

    /**
       Write the format string to an output range until the next format
       specifier is found and parse that format specifier.

       See $(LREF FormatSpec) for an example, how to use `writeUpToNextSpec`.

       Params:
           writer = the $(REF_ALTTEXT output range, isOutputRange, std, range, primitives)

       Returns:
           True, when a format specifier is found.

       Throws:
           A $(LREF FormatException) when the found format specifier
           could not be parsed.
     */
    bool writeUpToNextSpec(OutputRange)(ref OutputRange writer) scope
    {
        if (trailing.empty)
            return false;
        for (size_t i = 0; i < trailing.length; ++i)
        {
            if (trailing[i] != '%') continue;
            put(writer, trailing[0 .. i]);
            trailing = trailing[i .. $];
            enforceFmt(trailing.length >= 2, `Unterminated format specifier: "%"`);
            trailing = trailing[1 .. $];

            if (trailing[0] != '%')
            {
                // Spec found. Fill up the spec, and bailout
                fillUp();
                return true;
            }
            // Doubled! Reset and Keep going
            i = 0;
        }
        // no format spec found
        put(writer, trailing);
        trailing = null;
        return false;
    }

    private void fillUp() scope
    {
        // Reset content
        if (__ctfe)
        {
            flDash = false;
            flZero = false;
            flSpace = false;
            flPlus = false;
            flHash = false;
            flSeparator = false;
        }
        else
        {
            allFlags = 0;
        }

        width = 0;
        precision = UNSPECIFIED;
        nested = null;
        // Parse the spec (we assume we're past '%' already)
        for (size_t i = 0; i < trailing.length; )
        {
            switch (trailing[i])
            {
            case '(':
                // Embedded format specifier.
                auto j = i + 1;
                // Get the matching balanced paren
                for (uint innerParens;;)
                {
                    enforceFmt(j + 1 < trailing.length,
                        text("Incorrect format specifier: %", trailing[i .. $]));
                    if (trailing[j++] != '%')
                    {
                        // skip, we're waiting for %( and %)
                        continue;
                    }
                    if (trailing[j] == '-') // for %-(
                    {
                        ++j;    // skip
                        enforceFmt(j < trailing.length,
                            text("Incorrect format specifier: %", trailing[i .. $]));
                    }
                    if (trailing[j] == ')')
                    {
                        if (innerParens-- == 0) break;
                    }
                    else if (trailing[j] == '|')
                    {
                        if (innerParens == 0) break;
                    }
                    else if (trailing[j] == '(')
                    {
                        ++innerParens;
                    }
                }
                if (trailing[j] == '|')
                {
                    auto k = j;
                    for (++j;;)
                    {
                        if (trailing[j++] != '%')
                            continue;
                        if (trailing[j] == '%')
                            ++j;
                        else if (trailing[j] == ')')
                            break;
                        else
                            throw new FormatException(
                                text("Incorrect format specifier: %",
                                        trailing[j .. $]));
                    }
                    nested = trailing[i + 1 .. k - 1];
                    sep = trailing[k + 1 .. j - 1];
                }
                else
                {
                    nested = trailing[i + 1 .. j - 1];
                    sep = null; // no separator
                }
                //this = FormatSpec(innerTrailingSpec);
                spec = '(';
                // We practically found the format specifier
                trailing = trailing[j + 1 .. $];
                return;
            case '-': flDash = true; ++i; break;
            case '+': flPlus = true; ++i; break;
            case '#': flHash = true; ++i; break;
            case '0': flZero = true; ++i; break;
            case ' ': flSpace = true; ++i; break;
            case '*':
                if (isDigit(trailing[++i]))
                {
                    // a '*' followed by digits and '$' is a
                    // positional format
                    trailing = trailing[1 .. $];
                    width = -parse!(typeof(width))(trailing);
                    i = 0;
                    enforceFmt(trailing[i++] == '$',
                        "$ expected");
                }
                else
                {
                    // read result
                    width = DYNAMIC;
                }
                break;
            case '1': .. case '9':
                auto tmp = trailing[i .. $];
                const widthOrArgIndex = parse!uint(tmp);
                enforceFmt(tmp.length,
                    text("Incorrect format specifier %", trailing[i .. $]));
                i = arrayPtrDiff(tmp, trailing);
                if (tmp.startsWith('$'))
                {
                    // index of the form %n$
                    indexEnd = indexStart = to!ubyte(widthOrArgIndex);
                    ++i;
                }
                else if (tmp.startsWith(':'))
                {
                    // two indexes of the form %m:n$, or one index of the form %m:$
                    indexStart = to!ubyte(widthOrArgIndex);
                    tmp = tmp[1 .. $];
                    if (tmp.startsWith('$'))
                    {
                        indexEnd = indexEnd.max;
                    }
                    else
                    {
                        indexEnd = parse!(typeof(indexEnd))(tmp);
                    }
                    i = arrayPtrDiff(tmp, trailing);
                    enforceFmt(trailing[i++] == '$',
                        "$ expected");
                }
                else
                {
                    // width
                    width = to!int(widthOrArgIndex);
                }
                break;
            case ',':
                // Precision
                ++i;
                flSeparator = true;

                if (trailing[i] == '*')
                {
                    ++i;
                    // read result
                    separators = DYNAMIC;
                }
                else if (isDigit(trailing[i]))
                {
                    auto tmp = trailing[i .. $];
                    separators = parse!int(tmp);
                    i = arrayPtrDiff(tmp, trailing);
                }
                else
                {
                    // "," was specified, but nothing after it
                    separators = 3;
                }

                if (trailing[i] == '?')
                {
                    separatorCharPos = DYNAMIC;
                    ++i;
                }

                break;
            case '.':
                // Precision
                if (trailing[++i] == '*')
                {
                    if (isDigit(trailing[++i]))
                    {
                        // a '.*' followed by digits and '$' is a
                        // positional precision
                        trailing = trailing[i .. $];
                        i = 0;
                        precision = -parse!int(trailing);
                        enforceFmt(trailing[i++] == '$',
                            "$ expected");
                    }
                    else
                    {
                        // read result
                        precision = DYNAMIC;
                    }
                }
                else if (trailing[i] == '-')
                {
                    // negative precision, as good as 0
                    precision = 0;
                    auto tmp = trailing[i .. $];
                    parse!int(tmp); // skip digits
                    i = arrayPtrDiff(tmp, trailing);
                }
                else if (isDigit(trailing[i]))
                {
                    auto tmp = trailing[i .. $];
                    precision = parse!int(tmp);
                    i = arrayPtrDiff(tmp, trailing);
                }
                else
                {
                    // "." was specified, but nothing after it
                    precision = 0;
                }
                break;
            default:
                // this is the format char
                spec = cast(char) trailing[i++];
                trailing = trailing[i .. $];
                return;
            } // end switch
        } // end for
        throw new FormatException(text("Incorrect format specifier: ", trailing));
    }

    //--------------------------------------------------------------------------
    package bool readUpToNextSpec(R)(ref R r) scope
    {
        import std.ascii : isLower, isWhite;
        import std.utf : stride;

        // Reset content
        if (__ctfe)
        {
            flDash = false;
            flZero = false;
            flSpace = false;
            flPlus = false;
            flHash = false;
            flSeparator = false;
        }
        else
        {
            allFlags = 0;
        }
        width = 0;
        precision = UNSPECIFIED;
        nested = null;
        // Parse the spec
        while (trailing.length)
        {
            const c = trailing[0];
            if (c == '%' && trailing.length > 1)
            {
                const c2 = trailing[1];
                if (c2 == '%')
                {
                    assert(!r.empty, "Required at least one more input");
                    // Require a '%'
                    if (r.front != '%') break;
                    trailing = trailing[2 .. $];
                    r.popFront();
                }
                else
                {
                    enforceFmt(isLower(c2) || c2 == '*' || c2 == '(',
                        text("'%", c2, "' not supported with formatted read"));
                    trailing = trailing[1 .. $];
                    fillUp();
                    return true;
                }
            }
            else
            {
                if (c == ' ')
                {
                    while (!r.empty && isWhite(r.front)) r.popFront();
                    //r = std.algorithm.find!(not!(isWhite))(r);
                }
                else
                {
                    enforceFmt(!r.empty,
                        text("parseToFormatSpec: Cannot find character '",
                             c, "' in the input string."));
                    if (r.front != trailing.front) break;
                    r.popFront();
                }
                trailing = trailing[stride(trailing, 0) .. $];
            }
        }
        return false;
    }

    package string getCurFmtStr() const
    {
        import std.array : appender;

        auto w = appender!string();
        auto f = FormatSpec!Char("%s"); // for stringnize

        put(w, '%');
        if (indexStart != 0)
        {
            formatValue(w, indexStart, f);
            put(w, '$');
        }
        if (flDash) put(w, '-');
        if (flZero) put(w, '0');
        if (flSpace) put(w, ' ');
        if (flPlus) put(w, '+');
        if (flHash) put(w, '#');
        if (flSeparator) put(w, ',');
        if (width != 0)
            formatValue(w, width, f);
        if (precision != FormatSpec!Char.UNSPECIFIED)
        {
            put(w, '.');
            formatValue(w, precision, f);
        }
        put(w, spec);
        return w.data;
    }

    private const(Char)[] headUpToNextSpec()
    {
        import std.array : appender;

        auto w = appender!(typeof(return))();
        auto tr = trailing;

        while (tr.length)
        {
            if (tr[0] == '%')
            {
                if (tr.length > 1 && tr[1] == '%')
                {
                    tr = tr[2 .. $];
                    w.put('%');
                }
                else
                    break;
            }
            else
            {
                w.put(tr.front);
                tr.popFront();
            }
        }
        return w.data;
    }

    /**
     * Gives a string containing all of the member variables on their own
     * line.
     *
     * Params:
     *     writer = A `char` accepting
     *     $(REF_ALTTEXT output range, isOutputRange, std, range, primitives)
     * Returns:
     *     A `string` when not using an output range; `void` otherwise.
     */
    string toString() const @safe pure
    {
        import std.array : appender;

        auto app = appender!string();
        app.reserve(200 + trailing.length);
        toString(app);
        return app.data;
    }

    /// ditto
    void toString(OutputRange)(ref OutputRange writer) const
    if (isOutputRange!(OutputRange, char))
    {
        auto s = singleSpec("%s");

        put(writer, "address = ");
        formatValue(writer, &this, s);
        put(writer, "\nwidth = ");
        formatValue(writer, width, s);
        put(writer, "\nprecision = ");
        formatValue(writer, precision, s);
        put(writer, "\nspec = ");
        formatValue(writer, spec, s);
        put(writer, "\nindexStart = ");
        formatValue(writer, indexStart, s);
        put(writer, "\nindexEnd = ");
        formatValue(writer, indexEnd, s);
        put(writer, "\nflDash = ");
        formatValue(writer, flDash, s);
        put(writer, "\nflZero = ");
        formatValue(writer, flZero, s);
        put(writer, "\nflSpace = ");
        formatValue(writer, flSpace, s);
        put(writer, "\nflPlus = ");
        formatValue(writer, flPlus, s);
        put(writer, "\nflHash = ");
        formatValue(writer, flHash, s);
        put(writer, "\nflSeparator = ");
        formatValue(writer, flSeparator, s);
        put(writer, "\nnested = ");
        formatValue(writer, nested, s);
        put(writer, "\ntrailing = ");
        formatValue(writer, trailing, s);
        put(writer, '\n');
    }
}

@safe unittest
{
    import std.array : appender;
    import std.conv : text;
    import std.exception : assertThrown;

    auto w = appender!(char[])();
    auto f = FormatSpec!char("abc%sdef%sghi");
    f.writeUpToNextSpec(w);
    assert(w.data == "abc", w.data);
    assert(f.trailing == "def%sghi", text(f.trailing));
    f.writeUpToNextSpec(w);
    assert(w.data == "abcdef", w.data);
    assert(f.trailing == "ghi");
    // test with embedded %%s
    f = FormatSpec!char("ab%%cd%%ef%sg%%h%sij");
    w.clear();
    f.writeUpToNextSpec(w);
    assert(w.data == "ab%cd%ef" && f.trailing == "g%%h%sij", w.data);
    f.writeUpToNextSpec(w);
    assert(w.data == "ab%cd%efg%h" && f.trailing == "ij");
    // https://issues.dlang.org/show_bug.cgi?id=4775
    f = FormatSpec!char("%%%s");
    w.clear();
    f.writeUpToNextSpec(w);
    assert(w.data == "%" && f.trailing == "");
    f = FormatSpec!char("%%%%%s%%");
    w.clear();
    while (f.writeUpToNextSpec(w)) continue;
    assert(w.data == "%%%");

    f = FormatSpec!char("a%%b%%c%");
    w.clear();
    assertThrown!FormatException(f.writeUpToNextSpec(w));
    assert(w.data == "a%b%c" && f.trailing == "%");
}

// https://issues.dlang.org/show_bug.cgi?id=5237
@safe unittest
{
    import std.array : appender;

    auto w = appender!string();
    auto f = FormatSpec!char("%.16f");
    f.writeUpToNextSpec(w); // dummy eating
    assert(f.spec == 'f');
    auto fmt = f.getCurFmtStr();
    assert(fmt == "%.16f");
}

///
@safe pure unittest
{
    import std.array : appender;

    auto a = appender!(string)();
    auto fmt = "Number: %6.4e\nString: %s";
    auto f = FormatSpec!char(fmt);

    assert(f.writeUpToNextSpec(a) == true);

    assert(a.data == "Number: ");
    assert(f.trailing == "\nString: %s");
    assert(f.spec == 'e');
    assert(f.width == 6);
    assert(f.precision == 4);

    assert(f.writeUpToNextSpec(a) == true);

    assert(a.data == "Number: \nString: ");
    assert(f.trailing == "");
    assert(f.spec == 's');

    assert(f.writeUpToNextSpec(a) == false);
    assert(a.data == "Number: \nString: ");
}

// https://issues.dlang.org/show_bug.cgi?id=14059
@safe unittest
{
    import std.array : appender;
    import std.exception : assertThrown;

    auto a = appender!(string)();

    auto f = FormatSpec!char("%-(%s%"); // %)")
    assertThrown!FormatException(f.writeUpToNextSpec(a));

    f = FormatSpec!char("%(%-"); // %)")
    assertThrown!FormatException(f.writeUpToNextSpec(a));
}

@safe unittest
{
    import std.array : appender;

    auto a = appender!(string)();

    auto f = FormatSpec!char("%,d");
    f.writeUpToNextSpec(a);

    assert(f.spec == 'd', format("%s", f.spec));
    assert(f.precision == FormatSpec!char.UNSPECIFIED);
    assert(f.separators == 3);

    f = FormatSpec!char("%5,10f");
    f.writeUpToNextSpec(a);
    assert(f.spec == 'f', format("%s", f.spec));
    assert(f.separators == 10);
    assert(f.width == 5);

    f = FormatSpec!char("%5,10.4f");
    f.writeUpToNextSpec(a);
    assert(f.spec == 'f', format("%s", f.spec));
    assert(f.separators == 10);
    assert(f.width == 5);
    assert(f.precision == 4);
}

@safe pure unittest
{
    import std.algorithm.searching : canFind, findSplitBefore;

    auto expected = "width = 2" ~
        "\nprecision = 5" ~
        "\nspec = f" ~
        "\nindexStart = 0" ~
        "\nindexEnd = 0" ~
        "\nflDash = false" ~
        "\nflZero = false" ~
        "\nflSpace = false" ~
        "\nflPlus = false" ~
        "\nflHash = false" ~
        "\nflSeparator = false" ~
        "\nnested = " ~
        "\ntrailing = \n";
    auto spec = singleSpec("%2.5f");
    auto res = spec.toString();
    // make sure the address exists, then skip it
    assert(res.canFind("address"));
    assert(res.findSplitBefore("width")[1] == expected);
}

/**
Helper function that returns a `FormatSpec` for a single specifier given
in `fmt`.

Params:
    fmt = A format specifier.

Returns:
    A `FormatSpec` with the specifier parsed.
Throws:
    A `FormatException` when more than one specifier is given or the specifier
    is malformed.
  */
FormatSpec!Char singleSpec(Char)(Char[] fmt)
{
    import std.conv : text;
    import std.range.primitives : empty, front;

    enforceFmt(fmt.length >= 2, "fmt must be at least 2 characters long");
    enforceFmt(fmt.front == '%', "fmt must start with a '%' character");

    static struct DummyOutputRange
    {
        void put(C)(scope const C[] buf) {} // eat elements
    }
    auto a = DummyOutputRange();
    auto spec = FormatSpec!Char(fmt);
    //dummy write
    spec.writeUpToNextSpec(a);

    enforceFmt(spec.trailing.empty,
        text("Trailing characters in fmt string: '", spec.trailing));

    return spec;
}

///
@safe pure unittest
{
    import std.exception : assertThrown;
    import std.format : FormatException;

    auto spec = singleSpec("%2.3e");

    assert(spec.trailing == "");
    assert(spec.spec == 'e');
    assert(spec.width == 2);
    assert(spec.precision == 3);

    assertThrown!FormatException(singleSpec(""));
    assertThrown!FormatException(singleSpec("2.3e"));
    assertThrown!FormatException(singleSpec("%2.3eTest"));
}

void enforceValidFormatSpec(T, Char)(scope const ref FormatSpec!Char f)
{
    import std.range : isInputRange;
    import std.format.internal.write : hasToString, HasToStringResult;

    enum overload = hasToString!(T, Char);
    static if (
            overload != HasToStringResult.constCharSinkFormatSpec &&
            overload != HasToStringResult.constCharSinkFormatString &&
            overload != HasToStringResult.customPutWriterFormatSpec &&
            !isInputRange!T)
    {
        enforceFmt(f.spec == 's',
            "Expected '%s' format specifier for type '" ~ T.stringof ~ "'");
    }
}

@safe unittest
{
    import std.exception : collectExceptionMsg;

    // width/precision
    assert(collectExceptionMsg!FormatException(format("%*.d", 5.1, 2))
        == "integer width expected, not double for argument #1");
    assert(collectExceptionMsg!FormatException(format("%-1*.d", 5.1, 2))
        == "integer width expected, not double for argument #1");

    assert(collectExceptionMsg!FormatException(format("%.*d", '5', 2))
        == "integer precision expected, not char for argument #1");
    assert(collectExceptionMsg!FormatException(format("%-1.*d", 4.7, 3))
        == "integer precision expected, not double for argument #1");
    assert(collectExceptionMsg!FormatException(format("%.*d", 5))
        == "Orphan format specifier: %d");
    assert(collectExceptionMsg!FormatException(format("%*.*d", 5))
        == "Missing integer precision argument");

    // separatorCharPos
    assert(collectExceptionMsg!FormatException(format("%,?d", 5))
        == "separator character expected, not int for argument #1");
    assert(collectExceptionMsg!FormatException(format("%,?d", '?'))
        == "Orphan format specifier: %d");
    assert(collectExceptionMsg!FormatException(format("%.*,*?d", 5))
        == "Missing separator digit width argument");
}

