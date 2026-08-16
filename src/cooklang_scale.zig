//! Pure Cooklang scaling (semantic operation).
//!
//! Two surfaces, one exact-rational grammar (docs/COOKLANG.md §11):
//!
//! - String primitives — `classifyQuantity`, `parseFactor`,
//!   `scaleAmount` — so consumers that store amounts as authored text
//!   (not a typed `Recipe`) can classify and rewrite a quantity string
//!   without forking the arithmetic.
//! - `scaleRecipe` derives a new `Recipe` by calling `scaleAmount` on
//!   ingredient quantities only. It is a pure, deterministic operation:
//!   no filesystem, network, or global state, and the input recipe is
//!   never mutated.
//!
//! Semantics follow the official Cooklang conventions ("Scaling and
//! Servings", https://cooklang.org/docs/conventions/; provenance in
//! docs/CLEANROOM.md session 22, policy in docs/COOKLANG.md §11):
//!
//! - Ingredient quantities scale linearly by an exact rational factor.
//! - A fixed quantity — a leading `=` (`@salt{=1%tsp}`) — is left
//!   byte-for-byte unchanged.
//! - Recipe references (`@./path{2}`) are never touched: their
//!   quantities are directives for scaling the *referenced* recipe,
//!   which Oliver does not resolve (a consumer concern).
//! - Timers and cookware never scale (cooking times and pan sizes do
//!   not follow portion size).
//! - Non-numeric quantities (`@salt`, `@x{}`, `@x{two small}`) are
//!   unchanged — there is nothing numeric to scale.
//! - `.servings` mode reads the recipe's frontmatter `servings` /
//!   `serves` / `yield` key (leading number only, per the conventions;
//!   the default current count is 1) and scales by target / current.
//!
//! Arithmetic is exact: quantities are read as rationals directly from
//! their source text (never through f64), multiplied by the factor, and
//! reduced. A whole result emits an integer; a non-whole result emits a
//! reduced fraction, except a decimal-family source whose reduced
//! denominator has only 2 and 5 factors, which emits the exact
//! terminating decimal (bounded at 12 fractional digits). Results whose
//! exact representation would overflow 128-bit arithmetic are left
//! unchanged. Mixed numbers (`1 1/2`) are a canonical input form;
//! emission stays integer / fraction / terminating decimal.
//!
//! Ownership: the scaled `Recipe` owns a fresh arena; synthesized
//! quantity text lives in it. Everything else is a shallow copy of the
//! input model (borrowed source bytes and arena payloads are shared),
//! so the input recipe and its source bytes must outlive the scaled
//! result.

const std = @import("std");
const cooklang = @import("cooklang.zig");
const serialize = @import("cooklang_serialize.zig");

pub const ScaleError = error{ OutOfMemory, InvalidScaleFactor };

/// How to scale: by an exact rational factor `num/den`, or to a target
/// serving count (the current count is read from the recipe's
/// frontmatter per the conventions; `num`, `den`, and the target must
/// be non-zero — a zero numerator or denominator is
/// `error.InvalidScaleFactor`).
pub const ScaleBy = union(enum) {
    factor: cooklang.Fraction,
    servings: u32,
};

/// An exact rational scale factor (`num/den`). Zero numerator or
/// denominator is invalid (`error.InvalidScaleFactor`).
pub const ScaleFactor = struct {
    num: u64,
    den: u64,
};

/// The result of `scaleAmount`. `class` is always the input amount's
/// class; `changed` is false exactly when `scaled` aliases `original`
/// — for `empty` / `fixed` input, and for a scalable amount whose
/// exact rewrite was not representable (arithmetic overflow). Check
/// `changed` (or `scaled.ptr != original.ptr`) to tell whether a
/// rewrite happened; never assume `.scalable` implies one.
pub const ScaledAmount = struct {
    class: cooklang.QuantityClass,
    original: []const u8,
    scaled: []const u8,
    changed: bool,

    pub fn deinit(self: ScaledAmount, allocator: std.mem.Allocator) void {
        if (self.changed) allocator.free(self.scaled);
    }
};

pub const classifyQuantity = cooklang.classifyQuantity;
pub const QuantityClass = cooklang.QuantityClass;

/// Parses a scale factor as an exact rational. Accepts the same
/// canonical scalable forms as amounts (integer, `a/b`, decimal,
/// mixed). Zero, a zero denominator, and anything that is not a
/// scalable form are `error.InvalidScaleFactor`.
pub fn parseFactor(text: []const u8) ScaleError!ScaleFactor {
    const t = std.mem.trim(u8, text, " \t");
    const r = rationalOf(t) orelse return error.InvalidScaleFactor;
    if (r.num == 0) return error.InvalidScaleFactor;
    if (r.num > std.math.maxInt(u64) or r.den > std.math.maxInt(u64)) return error.InvalidScaleFactor;
    return .{ .num = @intCast(r.num), .den = @intCast(r.den) };
}

/// Scales one authored amount string. Scalable amounts become the
/// exact rational product under the same formatting policy as
/// `scaleRecipe`. Empty and fixed amounts (and overflow) leave
/// `scaled` aliasing `original`. A zero `num` or `den` is
/// `error.InvalidScaleFactor`.
pub fn scaleAmount(allocator: std.mem.Allocator, amount: []const u8, factor: ScaleFactor) ScaleError!ScaledAmount {
    if (factor.den == 0 or factor.num == 0) return error.InvalidScaleFactor;
    return scaleAmountBy(allocator, amount, Rational.of(factor.num, factor.den));
}

/// An exact non-negative rational, reduced after every operation.
const Rational = struct {
    num: u128,
    den: u128,

    fn of(num: u64, den: u64) Rational {
        return reduce(.{ .num = num, .den = den });
    }

    /// Fallible: an exact product that overflows u128 is null (callers
    /// then keep the original quantity — never a wrong number). A zero
    /// numerator is rejected by `factorOf` before any scaling, so this
    /// guard is defensive: it keeps the overflow precheck's division
    /// below from dividing by zero regardless of future callers.
    fn mul(a: Rational, b: Rational) ?Rational {
        if (b.num == 0) return null;
        if (a.num > std.math.maxInt(u128) / b.num) return null;
        if (a.den > std.math.maxInt(u128) / b.den) return null;
        return reduce(.{ .num = a.num * b.num, .den = a.den * b.den });
    }
};

fn reduce(r: Rational) Rational {
    const g = gcd(r.num, r.den);
    return .{ .num = r.num / g, .den = r.den / g };
}

fn gcd(a: u128, b: u128) u128 {
    var x = a;
    var y = b;
    while (y != 0) {
        const t = x % y;
        x = y;
        y = t;
    }
    return x;
}

// ---------------------------------------------------------------------------
// The operation.
// ---------------------------------------------------------------------------

/// Derives a scaled copy of `recipe`. The input recipe (and the source
/// bytes it borrows) must outlive the returned recipe.
pub fn scaleRecipe(allocator: std.mem.Allocator, recipe: *const cooklang.Recipe, by: ScaleBy) ScaleError!cooklang.Recipe {
    const factor = try factorOf(recipe, by);
    var out = cooklang.Recipe{
        .source = recipe.source,
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
    errdefer out.deinit();
    const a = out.allocator();
    out.frontmatter = recipe.frontmatter;
    out.blocks = try copyBlocks(a, recipe.blocks, factor);
    return out;
}

fn factorOf(recipe: *const cooklang.Recipe, by: ScaleBy) ScaleError!Rational {
    switch (by) {
        .factor => |f| {
            // A zero denominator is division by zero and a zero
            // numerator would scale everything to nothing — both are
            // degenerate, so both are rejected (docs/COOKLANG.md §11).
            if (f.den == 0) return error.InvalidScaleFactor;
            if (f.num == 0) return error.InvalidScaleFactor;
            return Rational.of(f.num, f.den);
        },
        .servings => |target| {
            if (target == 0) return error.InvalidScaleFactor;
            const current = servingsOf(recipe) orelse 1;
            return Rational.of(target, current);
        },
    }
}

/// The current serving count from the frontmatter, per the conventions:
/// the first line whose key is `servings`, `serves`, or `yield` and
/// whose value starts with a number; the leading number is the count
/// (anything after it is units). Null when absent, zero, or
/// non-numeric — callers default to 1. Oliver does not parse YAML; this
/// is a conservative line-oriented read of the raw payload only.
fn servingsOf(recipe: *const cooklang.Recipe) ?u32 {
    const fm = recipe.frontmatter orelse return null;
    var lines = std.mem.splitScalar(u8, fm.raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..colon], " \t");
        if (!std.mem.eql(u8, key, "servings") and
            !std.mem.eql(u8, key, "serves") and
            !std.mem.eql(u8, key, "yield")) continue;
        const value = std.mem.trimStart(u8, trimmed[colon + 1 ..], " \t");
        var i: usize = 0;
        while (i < value.len and value[i] >= '0' and value[i] <= '9') i += 1;
        if (i == 0) continue;
        const v = std.fmt.parseUnsigned(u32, value[0..i], 10) catch continue;
        if (v == 0) return null;
        return v;
    }
    return null;
}

fn copyBlocks(a: std.mem.Allocator, blocks: []const cooklang.Block, factor: Rational) ScaleError![]cooklang.Block {
    const out = try a.alloc(cooklang.Block, blocks.len);
    for (blocks, 0..) |b, i| out[i] = try copyBlock(a, b, factor);
    return out;
}

fn copyBlock(a: std.mem.Allocator, block: cooklang.Block, factor: Rational) ScaleError!cooklang.Block {
    switch (block) {
        .step => |step| return .{ .step = try copyStep(a, step, factor) },
        .note => |note| return .{ .note = note }, // plain text, never scaled
        .section => |sec| return .{
            .section = .{
                .name = sec.name,
                .name_span = sec.name_span,
                .span = sec.span,
                .blocks = try copyBlocks(a, sec.blocks, factor),
            },
        },
    }
}

fn copyStep(a: std.mem.Allocator, step: cooklang.Step, factor: Rational) ScaleError!cooklang.Step {
    const parts = try a.alloc(cooklang.Part, step.parts.len);
    for (step.parts, 0..) |p, i| parts[i] = try copyPart(a, p, factor);
    return .{ .parts = parts, .span = step.span };
}

fn copyPart(a: std.mem.Allocator, part: cooklang.Part, factor: Rational) ScaleError!cooklang.Part {
    switch (part) {
        .ingredient => |ig| {
            // Recipe references carry their own scaling directives and
            // are never rewritten. Everything else goes through the
            // public string operation (empty / fixed / overflow keep
            // the original slice).
            if (ig.is_recipe_reference) return part;
            const q = ig.quantity orelse return part;
            const result = try scaleAmountBy(a, q, factor);
            if (!result.changed) return part;
            var out = ig;
            out.quantity = result.scaled;
            // Re-derive the numeric view from the new text so the model
            // invariant holds (numeric == parseQuantity(quantity)).
            out.numeric = cooklang.parseQuantity(result.scaled);
            return .{ .ingredient = out };
        },
        // Text, line breaks, cookware, and timers are copied as-is.
        else => return part,
    }
}

/// The string operation `scaleRecipe` is built on. `scaled` aliases
/// `original` unless a new exact-rational rewrite was allocated.
fn scaleAmountBy(a: std.mem.Allocator, amount: []const u8, factor: Rational) ScaleError!ScaledAmount {
    const class = cooklang.classifyQuantity(amount);
    if (class != .scalable) {
        return .{ .class = class, .original = amount, .scaled = amount, .changed = false };
    }
    const trimmed = std.mem.trim(u8, amount, " \t");
    const r = rationalOf(trimmed) orelse {
        return .{ .class = class, .original = amount, .scaled = amount, .changed = false };
    };
    const prod = r.mul(factor) orelse {
        return .{ .class = class, .original = amount, .scaled = amount, .changed = false };
    };
    const family = familyOfAmount(trimmed);
    var buf: [NumBuf]u8 = undefined;
    const text = formatRational(prod, family, &buf) orelse {
        return .{ .class = class, .original = amount, .scaled = amount, .changed = false };
    };
    return .{ .class = class, .original = amount, .scaled = try a.dupe(u8, text), .changed = true };
}

/// The emission family from the source form, exactly — never through
/// f64 or `parseQuantity`'s i64-capped integer arm. Runs only after
/// `rationalOf` succeeded, so a `.` means the decimal arm parsed, a
/// canonical integer is the integer arm, and everything else (plain
/// fraction or mixed input) is a fraction family. This keeps the
/// terminating-decimal policy uniform at any magnitude: a decimal
/// source above i64 still emits the exact terminating decimal when
/// its reduced denominator is 2^a·5^b within the digit bound.
fn familyOfAmount(text: []const u8) Family {
    if (std.mem.indexOfScalar(u8, text, '.') != null) return .decimal;
    if (canonicalU64(text) != null) return .integer;
    return .fraction;
}

const Family = enum { integer, decimal, fraction };

// ---------------------------------------------------------------------------
// Exact rationals and formatting.
// ---------------------------------------------------------------------------

/// Formats the reduced rational `r`: an integer when whole; otherwise a
/// reduced fraction `num/den`, except a decimal-family source whose
/// denominator is `2^a·5^b` emits the exact terminating decimal.
/// Returns null when no canonical text fits the buffer.
const NumBuf = 96;

fn formatRational(r: Rational, family: Family, buf: *[NumBuf]u8) ?[]const u8 {
    if (r.den == 1) {
        return std.fmt.bufPrint(buf, "{d}", .{r.num}) catch null;
    }
    if (family == .decimal) {
        if (decimalText(r, buf)) |s| return s;
    }
    return std.fmt.bufPrint(buf, "{d}/{d}", .{ r.num, r.den }) catch null;
}

/// Exact terminating-decimal text for a reduced rational whose
/// denominator has only 2 and 5 factors, when the fractional part fits
/// in `MaxDecimalDigits` digits. Null otherwise (callers fall back to
/// the always-exact fraction).
const MaxDecimalDigits: u32 = 12;

fn decimalText(r: Rational, buf: *[NumBuf]u8) ?[]const u8 {
    var d = r.den;
    var twos: u32 = 0;
    var fives: u32 = 0;
    while (d % 2 == 0) : (d /= 2) twos += 1;
    while (d % 5 == 0) : (d /= 5) fives += 1;
    if (d != 1) return null;
    const k = @max(twos, fives);
    if (k > MaxDecimalDigits) return null;
    const p = pow10(k);
    const scale = p / r.den; // exact: 10^k = 2^k·5^k is a multiple of den
    if (r.num > std.math.maxInt(u128) / scale) return null;
    const scaled = r.num * scale;
    const whole = scaled / p;
    var frac = scaled % p;
    if (frac == 0) return std.fmt.bufPrint(buf, "{d}", .{whole}) catch null;
    // Zero-pad the fraction to k digits, then trim trailing zeros
    // ("0.25", "1.5", never "1.50" or "0.0500").
    var digits: [MaxDecimalDigits]u8 = undefined;
    var i: usize = k;
    while (i > 0) {
        i -= 1;
        digits[i] = '0' + @as(u8, @intCast(frac % 10));
        frac /= 10;
    }
    var end: usize = k;
    while (end > 0 and digits[end - 1] == '0') end -= 1;
    return std.fmt.bufPrint(buf, "{d}.{s}", .{ whole, digits[0..end] }) catch null;
}

fn pow10(k: u32) u128 {
    var v: u128 = 1;
    var i: u32 = 0;
    while (i < k) : (i += 1) v *= 10;
    return v;
}

/// Exact rational of a canonical quantity text: an integer (`0` or
/// `[1-9][0-9]*`), a decimal (`ip.fp`, integer part canonical, digit
/// fraction), a fraction of two canonical integers with a non-zero
/// denominator (spaces around the slash allowed, per the corpus), or
/// a mixed number `a b/c` (whole + proper fraction). This mirrors
/// `classifyQuantity` / `parseQuantity` acceptance but exactly — no f64.
/// Null when not canonical or when the exact rational exceeds 64-bit
/// bounds.
fn rationalOf(text: []const u8) ?Rational {
    if (canonicalU64(text)) |v| return Rational.of(v, 1);
    if (std.mem.indexOfScalar(u8, text, '.')) |d| {
        const ip = text[0..d];
        const fp = text[d + 1 ..];
        if (fp.len == 0 or !isDigits(fp)) return null;
        const ipv = canonicalU64(ip) orelse return null;
        const fpv = parseDigitsU64(fp) orelse return null;
        const k: u32 = @intCast(fp.len);
        const p = pow10(k);
        return reduce(.{ .num = @as(u128, ipv) * p + fpv, .den = p });
    }
    if (cooklang.parseMixedNumber(text)) |m| {
        const whole_part = std.math.mul(u64, m.whole, m.den) catch return null;
        const n = std.math.add(u64, whole_part, m.num) catch return null;
        return Rational.of(n, m.den);
    }
    if (std.mem.indexOfScalar(u8, text, '/')) |s| {
        const num = canonicalU64(std.mem.trim(u8, text[0..s], " \t")) orelse return null;
        const den = canonicalU64(std.mem.trim(u8, text[s + 1 ..], " \t")) orelse return null;
        if (den == 0) return null;
        return Rational.of(num, den);
    }
    return null;
}

/// `"0"` or `[1-9][0-9]*` as u64.
fn canonicalU64(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    if (text[0] == '0') return if (text.len == 1) 0 else null;
    return parseDigitsU64(text);
}

/// Any all-digit run (leading zeros allowed) as u64, when it fits.
fn parseDigitsU64(text: []const u8) ?u64 {
    if (!isDigits(text)) return null;
    return std.fmt.parseUnsigned(u64, text, 10) catch null;
}

fn isDigits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

/// Parses `input`, scales it, and serializes the scaled recipe
/// (parse -> scale -> serialize is the observable contract).
fn scaleT(allocator: std.mem.Allocator, input: []const u8, by: ScaleBy) ![]const u8 {
    var result = try cooklang.parse(allocator, input, .{});
    defer result.deinit();
    var scaled = try scaleRecipe(allocator, &result.recipe, by);
    defer scaled.deinit();
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try serialize.serialize(allocator, &aw.writer, &scaled, .{});
    var list = aw.toArrayList();
    return try list.toOwnedSlice(allocator);
}

test "cooklang scale: factor scales canonical quantities exactly" {
    // Integers, fractions, decimals; doubling and tripling; scaling down.
    const cases = [_]struct { input: []const u8, by: ScaleBy, expected: []const u8 }{
        .{ .input = "Mix @flour{200%g} and @water{300%ml}.", .by = .{ .factor = .{ .num = 2, .den = 1 } }, .expected = "Mix @flour{400%g} and @water{600%ml}.\n" },
        .{ .input = "@milk{1/2%cup}", .by = .{ .factor = .{ .num = 2, .den = 1 } }, .expected = "@milk{1%cup}\n" },
        .{ .input = "@milk{1/2%cup}", .by = .{ .factor = .{ .num = 3, .den = 1 } }, .expected = "@milk{3/2%cup}\n" },
        .{ .input = "@x{1.5%l}", .by = .{ .factor = .{ .num = 3, .den = 1 } }, .expected = "@x{4.5%l}\n" },
        .{ .input = "@flour{200%g}", .by = .{ .factor = .{ .num = 1, .den = 2 } }, .expected = "@flour{100%g}\n" },
        .{ .input = "@milk{1/2%cup}", .by = .{ .factor = .{ .num = 1, .den = 2 } }, .expected = "@milk{1/4%cup}\n" },
        .{ .input = "@y{2}", .by = .{ .factor = .{ .num = 4, .den = 3 } }, .expected = "@y{8/3}\n" },
        .{ .input = "@z{0.1%g}", .by = .{ .factor = .{ .num = 3, .den = 1 } }, .expected = "@z{0.3%g}\n" },
        .{ .input = "@w{0.5}", .by = .{ .factor = .{ .num = 1, .den = 1 } }, .expected = "@w{0.5}\n" },
    };
    for (cases) |c| {
        const out = try scaleT(std.testing.allocator, c.input, c.by);
        defer std.testing.allocator.free(out);
        try std.testing.expectEqualStrings(c.expected, out);
    }
}

test "cooklang scale: fixed quantities stay locked" {
    const out = try scaleT(std.testing.allocator, "Season with @salt{=1%tsp} to taste.", .{ .factor = .{ .num = 4, .den = 1 } });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("Season with @salt{=1%tsp} to taste.\n", out);
}

test "cooklang scale: references, timers, and cookware never scale" {
    const input = "Add @./sauces/Hollandaise{150%g} and fry in #frying pan{2} for ~{25%minutes}, then ~eggs{3%minutes}.";
    const out = try scaleT(std.testing.allocator, input, .{ .factor = .{ .num = 3, .den = 1 } });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(input ++ "\n", out);
}

test "cooklang scale: non-numeric quantities stay unchanged" {
    // The canonical serializer normalizes `{ }` to `{}` (empty braces),
    // but the quantity itself is never rewritten by scaling.
    const input = "Add @salt and @pepper{} and @x{two small} and @y{ }.";
    const out = try scaleT(std.testing.allocator, input, .{ .factor = .{ .num = 2, .den = 1 } });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("Add @salt and @pepper{} and @x{two small} and @y{}.\n", out);
}

test "cooklang scale: servings mode reads frontmatter" {
    // servings: 2, scale to 4 -> double.
    const a = try scaleT(std.testing.allocator, "---\nservings: 2\n---\n\nAdd @milk{1/2%cup}.", .{ .servings = 4 });
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("---\nservings: 2\n---\n\nAdd @milk{1%cup}.\n", a);

    // No servings metadata -> default 1, scale to 4 -> quadruple.
    const b = try scaleT(std.testing.allocator, "Add @milk{1/2%cup}.", .{ .servings = 4 });
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("Add @milk{2%cup}.\n", b);

    // yield: 15 cups worth -> current 15; serves: 6 -> double.
    const c = try scaleT(std.testing.allocator, "---\nyield: 15 cups worth\n---\n\nAdd @x{150%g}.", .{ .servings = 30 });
    defer std.testing.allocator.free(c);
    try std.testing.expectEqualStrings("---\nyield: 15 cups worth\n---\n\nAdd @x{300%g}.\n", c);
    const d = try scaleT(std.testing.allocator, "---\nserves: 6\n---\n\nAdd @x{1%l}.", .{ .servings = 12 });
    defer std.testing.allocator.free(d);
    try std.testing.expectEqualStrings("---\nserves: 6\n---\n\nAdd @x{2%l}.\n", d);

    // A non-numeric value falls back to the default of 1.
    const e = try scaleT(std.testing.allocator, "---\nservings: many\n---\n\nAdd @x{1%l}.", .{ .servings = 3 });
    defer std.testing.allocator.free(e);
    try std.testing.expectEqualStrings("---\nservings: many\n---\n\nAdd @x{3%l}.\n", e);
}

test "cooklang scale: exactness — non-terminating decimals become fractions" {
    // 0.1 × 4/3 = 2/15: a decimal family whose denominator is not 2^a·5^b
    // emits the exact fraction, never a rounded decimal.
    const out = try scaleT(std.testing.allocator, "@x{0.1%g}", .{ .factor = .{ .num = 4, .den = 3 } });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("@x{2/15%g}\n", out);
}

test "cooklang scale: sections recurse, notes and text untouched" {
    const input = "= Dough\n\nMix @flour{200%g}.\n\n> Keep the @salt nearby.\n\n== Filling ==\nCombine @cheese{100%g}(grated).";
    const out = try scaleT(std.testing.allocator, input, .{ .factor = .{ .num = 2, .den = 1 } });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("= Dough\n\nMix @flour{400%g}.\n\n> Keep the @salt nearby.\n\n= Filling\n\nCombine @cheese{200%g}(grated).\n", out);
}

test "cooklang scale: invalid factors are rejected, not guessed" {
    var r = try cooklang.parse(std.testing.allocator, "", .{});
    defer r.deinit();
    // Zero denominator (division by zero) and zero numerator (scaling to
    // nothing) are both degenerate; zero servings is the same shape.
    // Regression: a zero numerator used to panic with a division by zero
    // inside `Rational.mul` (issue #55) instead of returning an error.
    try std.testing.expectError(error.InvalidScaleFactor, scaleRecipe(std.testing.allocator, &r.recipe, .{ .factor = .{ .num = 1, .den = 0 } }));
    try std.testing.expectError(error.InvalidScaleFactor, scaleRecipe(std.testing.allocator, &r.recipe, .{ .factor = .{ .num = 0, .den = 1 } }));
    try std.testing.expectError(error.InvalidScaleFactor, scaleRecipe(std.testing.allocator, &r.recipe, .{ .factor = .{ .num = 0, .den = 2 } }));
    try std.testing.expectError(error.InvalidScaleFactor, scaleRecipe(std.testing.allocator, &r.recipe, .{ .servings = 0 }));
}

test "cooklang scale: scaled recipe re-parses with consistent numeric views" {
    var result = try cooklang.parse(std.testing.allocator, "Add @milk{1/2%cup} and @flour{200%g}.", .{});
    defer result.deinit();
    var scaled = try scaleRecipe(std.testing.allocator, &result.recipe, .{ .factor = .{ .num = 2, .den = 1 } });
    defer scaled.deinit();
    const step = scaled.blocks[0].step;
    // milk 1/2 -> 1, flour 200 -> 400; numeric views recomputed.
    const milk = step.parts[1].ingredient;
    try std.testing.expectEqualStrings("1", milk.quantity.?);
    try std.testing.expectEqual(cooklang.Quantity{ .int = 1 }, milk.numeric.?);
    const flour = step.parts[3].ingredient;
    try std.testing.expectEqualStrings("400", flour.quantity.?);
    try std.testing.expectEqual(cooklang.Quantity{ .int = 400 }, flour.numeric.?);
}

test "cooklang scale: empty and frontmatter-only inputs" {
    const a = try scaleT(std.testing.allocator, "", .{ .factor = .{ .num = 2, .den = 1 } });
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("", a);
    const b = try scaleT(std.testing.allocator, "---\n---\n\nAdd @salt.", .{ .factor = .{ .num = 2, .den = 1 } });
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("---\n---\n\nAdd @salt.\n", b);
}

test "cooklang scale: scaleAmount public string API" {
    const allocator = std.testing.allocator;
    const double = try parseFactor("2");
    var half = try scaleAmount(allocator, "1/2", double);
    defer half.deinit(allocator);
    try std.testing.expectEqual(QuantityClass.scalable, half.class);
    try std.testing.expectEqualStrings("1", half.scaled);

    const triple = try parseFactor("3");
    var decimal = try scaleAmount(allocator, "1.5", triple);
    defer decimal.deinit(allocator);
    try std.testing.expectEqualStrings("4.5", decimal.scaled);

    var locked = try scaleAmount(allocator, "=1", .{ .num = 4, .den = 1 });
    defer locked.deinit(allocator);
    try std.testing.expectEqual(QuantityClass.fixed, locked.class);
    try std.testing.expectEqualStrings("=1", locked.scaled);
    try std.testing.expect(locked.scaled.ptr == locked.original.ptr);

    var empty = try scaleAmount(allocator, "", double);
    defer empty.deinit(allocator);
    try std.testing.expectEqual(QuantityClass.empty, empty.class);
    try std.testing.expect(empty.scaled.ptr == empty.original.ptr);

    try std.testing.expectError(error.InvalidScaleFactor, scaleAmount(allocator, "1", .{ .num = 0, .den = 1 }));
    try std.testing.expectError(error.InvalidScaleFactor, parseFactor("0"));
    try std.testing.expectError(error.InvalidScaleFactor, parseFactor("1/0"));
    try std.testing.expectError(error.InvalidScaleFactor, parseFactor("some"));
}

test "cooklang scale: mixed numbers scale through the string and recipe APIs" {
    const allocator = std.testing.allocator;
    const double = try parseFactor("2");
    var mixed = try scaleAmount(allocator, "1 1/2", double);
    defer mixed.deinit(allocator);
    try std.testing.expectEqual(QuantityClass.scalable, mixed.class);
    try std.testing.expectEqualStrings("3", mixed.scaled);

    // Identity factor still emits the integer/fraction policy, not mixed.
    var ident = try scaleAmount(allocator, "1 1/2", .{ .num = 1, .den = 1 });
    defer ident.deinit(allocator);
    try std.testing.expectEqualStrings("3/2", ident.scaled);

    const out = try scaleT(allocator, "Add @flour{1 1/2%cup} and @salt{=1%tsp} and fry in #pot{2} for ~{9%minutes}, then @./sauce{2}.", .{ .factor = .{ .num = 2, .den = 1 } });
    defer allocator.free(out);
    try std.testing.expectEqualStrings("Add @flour{3%cup} and @salt{=1%tsp} and fry in #pot{2} for ~{9%minutes}, then @./sauce{2}.\n", out);
}

test "cooklang scale: decimal-family emission is exact at any magnitude" {
    const allocator = std.testing.allocator;
    const id: ScaleFactor = .{ .num = 1, .den = 1 };
    const dbl: ScaleFactor = .{ .num = 2, .den = 1 };

    // Control: a small decimal stays decimal under identity.
    var control = try scaleAmount(allocator, "1.5", id);
    defer control.deinit(allocator);
    try std.testing.expectEqualStrings("1.5", control.scaled);

    // The same decimal shape above i64 now emits the exact terminating
    // decimal (issue #80: the f64/i64 family probe emitted a fraction).
    var big = try scaleAmount(allocator, "9223372036854775808.5", id);
    defer big.deinit(allocator);
    try std.testing.expectEqualStrings("9223372036854775808.5", big.scaled);

    // A 12-digit decimal within the digit bound emits the exact
    // terminating decimal, not a fraction.
    var twelve = try scaleAmount(allocator, "18446744073709551615.999999999999", id);
    defer twelve.deinit(allocator);
    try std.testing.expectEqualStrings("18446744073709551615.999999999999", twelve.scaled);

    // Scaled: 2x stays an exact terminating decimal at the same magnitude.
    var doubled = try scaleAmount(allocator, "18446744073709551615.999999999999", dbl);
    defer doubled.deinit(allocator);
    try std.testing.expectEqualStrings("36893488147419103231.999999999998", doubled.scaled);

    // A whole product above i64 emits an integer.
    var whole = try scaleAmount(allocator, "9223372036854775808.5", dbl);
    defer whole.deinit(allocator);
    try std.testing.expectEqualStrings("18446744073709551617", whole.scaled);

    // Past the digit bound the fallback is still the exact fraction
    // (never a rounded decimal), for any magnitude.
    var fallback = try scaleAmount(allocator, "0.0000000000001", id);
    defer fallback.deinit(allocator);
    try std.testing.expectEqualStrings("1/10000000000000", fallback.scaled);
}

test "cooklang scale: changed flag distinguishes rewrite from passthrough" {
    const allocator = std.testing.allocator;
    const maxu64: u64 = 18446744073709551615;
    const id: ScaleFactor = .{ .num = 1, .den = 1 };

    // Normal rewrite: changed == true, scaled is a fresh allocation.
    var r = try scaleAmount(allocator, "1/2", .{ .num = 2, .den = 1 });
    defer r.deinit(allocator);
    try std.testing.expect(r.changed);
    try std.testing.expect(r.scaled.ptr != r.original.ptr);
    try std.testing.expectEqualStrings("1", r.scaled);

    // Empty and fixed inputs: changed == false, scaled aliases original.
    var empty = try scaleAmount(allocator, "", id);
    defer empty.deinit(allocator);
    try std.testing.expect(!empty.changed);
    try std.testing.expect(empty.scaled.ptr == empty.original.ptr);

    var locked = try scaleAmount(allocator, "=1", id);
    defer locked.deinit(allocator);
    try std.testing.expect(!locked.changed);
    try std.testing.expect(locked.scaled.ptr == locked.original.ptr);

    // Passthrough triggers (issue #81): class stays .scalable — the
    // amount IS scalable — but changed == false tells the consumer no
    // rewrite happened.
    // 1. Exact product overflows 128-bit arithmetic.
    var overflow = try scaleAmount(allocator, "18446744073709551615.999999999999", .{ .num = maxu64, .den = 1 });
    defer overflow.deinit(allocator);
    try std.testing.expectEqual(QuantityClass.scalable, overflow.class);
    try std.testing.expect(!overflow.changed);
    try std.testing.expect(overflow.scaled.ptr == overflow.original.ptr);

    // 2. Fractional part exceeds u64 in the exact rational.
    var fp = try scaleAmount(allocator, "1.99999999999999999999", id);
    defer fp.deinit(allocator);
    try std.testing.expectEqual(QuantityClass.scalable, fp.class);
    try std.testing.expect(!fp.changed);

    // 3. Mixed whole*den exceeds u64.
    var mixed = try scaleAmount(allocator, "18446744073709551615 1/2", id);
    defer mixed.deinit(allocator);
    try std.testing.expectEqual(QuantityClass.scalable, mixed.class);
    try std.testing.expect(!mixed.changed);
    try std.testing.expect(mixed.scaled.ptr == mixed.original.ptr);
}
