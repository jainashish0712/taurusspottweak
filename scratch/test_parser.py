import sys

VALUE = 258
IDENTIFIER = 259
STRING_LITERAL = 260
STRING_IDENTIFIER = 261
TOKEN_SHL = 262
TOKEN_SHR = 263
TOKEN_LTE = 264
TOKEN_GTE = 265
TOKEN_EQ = 266
TOKEN_EQ_EXACT = 267
TOKEN_NE = 268
TOKEN_NE_EXACT = 269
TOKEN_LOGICAL_AND = 270
TOKEN_LOGICAL_OR = 271
TOKEN_ADD_OP = 272
TOKEN_SUB_OP = 273
TOKEN_MOD_OP = 274
TOKEN_OR_OP = 275
TOKEN_AND_OP = 276
TOKEN_XOR_OP = 277
TOKEN_DIV_OP = 278
TOKEN_MUL_OP = 279
TOKEN_POW_OP = 280

def isspace_safe(c):
    return c in ' \t\r\n'

def isalpha_safe(c):
    return ('a' <= c <= 'z') or ('A' <= c <= 'Z')

def isalnum_safe(c):
    return isalpha_safe(c) or ('0' <= c <= '9')

def nseel_skip_space_and_comments(s, p):
    while p < len(s):
        while p < len(s) and isspace_safe(s[p]):
            p += 1
        if p >= len(s) - 1 or s[p] != '/':
            return p
        if s[p+1] == '/':
            while p < len(s) and s[p] not in '\r\n':
                p += 1
        elif s[p+1] == '*':
            p += 2
            while p < len(s) - 1 and not (s[p] == '*' and s[p+1] == '/'):
                p += 1
            p += 2
        else:
            return p
    return p

def nseel_simple_tokenizer(s, p, state_in=None):
    state = state_in[0] if state_in else None
    if state_in is not None:
        if state == 1:
            while p < len(s):
                c = s[p]
                p += 1
                if c == '*' and p < len(s) and s[p] == '/':
                    p += 1
                    state_in[0] = 0
                    break
            return None, p
        while p < len(s) and isspace_safe(s[p]):
            p += 1
    else:
        p = nseel_skip_space_and_comments(s, p)

    if p >= len(s):
        return None, p

    rv = p
    c = s[p]
    if c == '$' and p + 3 < len(s) and s[p+1] == '\'' and s[p+3] == '\'':
        p += 4
    elif state_in is not None and c == '/' and p < len(s) - 1 and s[p+1] in '/*':
        if s[p+1] == '/':
            while p < len(s) and s[p] not in '\r\n':
                p += 1
        else:
            state_in[0] = 1
            p += 2
            while p < len(s):
                c2 = s[p]
                p += 1
                if c2 == '*' and p < len(s) and s[p] == '/':
                    p += 1
                    state_in[0] = 0
                    break
    elif isalnum_safe(c) or c in '_#$' or (c == '.' and p < len(s) - 1 and '0' <= s[p+1] <= '9'):
        is_num = ('0' <= c <= '9') or (c == '.' and p < len(s) - 1 and '0' <= s[p+1] <= '9')
        if c == '$' and p < len(s) - 1 and s[p+1] == '~':
            p += 1
        p += 1
        while p < len(s):
            if isalnum_safe(s[p]) or s[p] in '_.':
                if is_num and s[p] in 'eE' and p + 2 < len(s) and s[p+1] in '+-' and '0' <= s[p+2] <= '9':
                    p += 2
                else:
                    p += 1
            else:
                break
    elif c in '\'\"':
        delim = c
        p += 1
        if state_in is not None:
            state_in[0] = ord(delim)
        while p < len(s):
            ch = s[p]
            p += 1
            if p < len(s) and ch == '\\':
                p += 1
            elif ch == delim:
                if state_in is not None:
                    state_in[0] = 0
                break
    else:
        p += 1

    tok = s[rv:p]
    return tok, p

class Lexer:
    def __init__(self, s):
        self.s = s
        self.p = 0

    def next_token(self):
        tok, self.p = nseel_simple_tokenizer(self.s, self.p)
        if not tok:
            return 0, None
        rv = ord(tok[0]) if len(tok) == 1 else tok[0]
        toklen = len(tok)
        if (tok[0] in '0$' and toklen > 1 and tok[1] in 'xX'):
            return VALUE, tok
        elif tok[0] == '\'':
            return VALUE, tok
        elif tok[0] == '\"':
            return STRING_LITERAL, tok
        elif isalpha_safe(tok[0]) or tok[0] == '_':
            return IDENTIFIER, tok
        elif ('0' <= tok[0] <= '9') or (tok[0] == '.' and toklen > 1 and '0' <= tok[1] <= '9'):
            x = 0
            pcnt = 0
            ecnt = 0
            idx = 0
            while idx < toklen:
                ch = tok[idx]
                if ch == '.':
                    pcnt += 1
                    if pcnt > 1 or ecnt > 0:
                        break
                elif ch in 'eE':
                    ecnt += 1
                    if ecnt > 1 or idx == 0 or idx == toklen - 1:
                        break
                    if idx + 1 < toklen and tok[idx+1] in '+-':
                        idx += 1
                        if idx == toklen - 1:
                            break
                elif not ('0' <= ch <= '9'):
                    break
                idx += 1
            if idx == toklen:
                return VALUE, tok
            else:
                return ord(tok[0]), tok
        elif tok[0] == '$' and toklen > 1:
            return VALUE, tok
        elif tok[0] == '<':
            if self.p < len(self.s) and self.s[self.p] == '<':
                self.p += 1
                return TOKEN_SHL, "<<"
            elif self.p < len(self.s) and self.s[self.p] == '=':
                self.p += 1
                return TOKEN_LTE, "<="
            return ord('<'), '<'
        elif tok[0] == '>':
            if self.p < len(self.s) and self.s[self.p] == '>':
                self.p += 1
                return TOKEN_SHR, ">>"
            elif self.p < len(self.s) and self.s[self.p] == '=':
                self.p += 1
                return TOKEN_GTE, ">="
            return ord('>'), '>'
        elif tok[0] == '&':
            if self.p < len(self.s) and self.s[self.p] == '&':
                self.p += 1
                return TOKEN_LOGICAL_AND, "&&"
            elif self.p < len(self.s) and self.s[self.p] == '=':
                self.p += 1
                return TOKEN_AND_OP, "&="
            return ord('&'), '&'
        elif tok[0] == '|':
            if self.p < len(self.s) and self.s[self.p] == '|':
                self.p += 1
                return TOKEN_LOGICAL_OR, "||"
            elif self.p < len(self.s) and self.s[self.p] == '=':
                self.p += 1
                return TOKEN_OR_OP, "|="
            return ord('|'), '|'
        elif self.p < len(self.s) and self.s[self.p] == '=':
            self.p += 1
            mapping = {
                '+': TOKEN_ADD_OP, '-': TOKEN_SUB_OP, '%': TOKEN_MOD_OP,
                '~': TOKEN_XOR_OP, '/': TOKEN_DIV_OP, '*': TOKEN_MUL_OP,
                '^': TOKEN_POW_OP
            }
            if tok[0] in mapping:
                return mapping[tok[0]], tok[0] + "="
            elif tok[0] == '!':
                if self.p < len(self.s) and self.s[self.p] == '=':
                    self.p += 1
                    return TOKEN_NE_EXACT, "!=="
                return TOKEN_NE, "!="
            elif tok[0] == '=':
                if self.p < len(self.s) and self.s[self.p] == '=':
                    self.p += 1
                    return TOKEN_EQ_EXACT, "==="
                return TOKEN_EQ, "=="
            return ord(tok[0]), tok[0]
        else:
            return ord(tok[0]), tok[0]

class Parser:
    def __init__(self, lexer):
        self.lexer = lexer
        self.token = None
        self.value = None
        self.failed = False
        self.advance()

    def advance(self):
        self.token, self.value = self.lexer.next_token()

    def fail(self, msg=""):
        if not self.failed:
            self.failed = True
            print(f"FAIL at token={self.token} (val={self.value}): {msg}")
        return None

    def starts_expression(self, tok):
        return tok in (VALUE, IDENTIFIER, STRING_LITERAL, STRING_IDENTIFIER, ord('('), ord('+'), ord('-'), ord('!'))

    def primary(self):
        if self.token == VALUE:
            val = self.value
            self.advance()
            return ("VALUE", val)
        elif self.token == STRING_LITERAL:
            val = self.value
            self.advance()
            return ("STR", val)
        elif self.token == IDENTIFIER:
            name = self.value
            self.advance()
            if self.token == ord('('):
                return self.call(name)
            return ("ID", name)
        elif self.token == ord('('):
            self.advance()
            inner = self.expression()
            if self.failed: return None
            if self.token != ord(')'):
                return self.fail("expected ')'")
            self.advance()
            return inner
        return self.fail(f"unexpected primary token {self.token}")

    def call(self, name):
        self.advance()
        if self.token == ord(')'):
            self.advance()
            return ("CALL0", name)
        first = self.expression()
        if self.failed: return None
        if self.token == ord(')'):
            self.advance()
            if self.token == ord('('):
                self.advance()
                post = self.expression()
                if self.failed: return None
                if self.token != ord(')'):
                    return self.fail("expected ')' in post call")
                self.advance()
                return ("WHILE", name, first, post)
            return ("CALL1", name, first)
        elif self.token == ord(','):
            self.advance()
            second = self.expression()
            if self.failed: return None
            if self.token == ord(')'):
                self.advance()
                return ("CALL2", name, first, second)
            elif self.token == ord(','):
                self.advance()
                rest = self.more_parameters()
                if self.failed: return None
                if self.token != ord(')'):
                    return self.fail("expected ')' in call")
                self.advance()
                return ("CALLN", name, first, second, rest)
            else:
                return self.fail("expected ')' or ',' in call")
        return self.fail("expected ')' or ',' after first arg")

    def more_parameters(self):
        first = self.expression()
        if self.failed: return None
        result = [first]
        if self.token == ord(','):
            self.advance()
            rest = self.more_parameters()
            if self.failed: return None
            result.extend(rest)
        return result

    def subscripts(self, target):
        while not self.failed and self.token == ord('['):
            self.advance()
            idx = None
            if self.token != ord(']'):
                idx = self.expression()
                if self.failed: return None
                if self.token != ord(']'):
                    return self.fail("expected ']'")
            self.advance()
            target = ("INDEX", target, idx)
        return target

    def assignment(self):
        target = self.primary()
        if self.failed: return None
        target = self.subscripts(target)
        if self.failed: return None
        if self.token in (ord('='), TOKEN_ADD_OP, TOKEN_SUB_OP, TOKEN_MOD_OP, TOKEN_OR_OP, TOKEN_AND_OP, TOKEN_XOR_OP, TOKEN_DIV_OP, TOKEN_MUL_OP, TOKEN_POW_OP):
            op = self.token
            self.advance()
            src = self.if_else()
            return ("ASSIGN", op, target, src)
        return target

    def unary(self):
        if self.token not in (ord('+'), ord('-'), ord('!')):
            return self.assignment()
        op = self.token
        self.advance()
        operand = self.unary()
        return ("UNARY", op, operand)

    def binary(self, next_fn, ops):
        left = next_fn()
        while not self.failed and self.token in ops:
            op = self.token
            self.advance()
            right = next_fn()
            left = ("BIN", op, left, right)
        return left

    def powers(self): return self.binary(self.unary, [ord('^')])
    def modulos(self): return self.binary(self.powers, [ord('%'), TOKEN_SHL, TOKEN_SHR])
    def divisions(self): return self.binary(self.modulos, [ord('/')])
    def products(self): return self.binary(self.divisions, [ord('*')])
    def differences(self): return self.binary(self.products, [ord('-')])
    def sums(self): return self.binary(self.differences, [ord('+')])
    def bitwise(self): return self.binary(self.sums, [ord('&'), ord('|'), ord('~')])
    def comparisons(self): return self.binary(self.bitwise, [ord('<'), ord('>'), TOKEN_LTE, TOKEN_GTE, TOKEN_EQ, TOKEN_EQ_EXACT, TOKEN_NE, TOKEN_NE_EXACT])
    def logical(self): return self.binary(self.comparisons, [TOKEN_LOGICAL_AND, TOKEN_LOGICAL_OR])

    def if_else(self):
        cond = self.logical()
        if self.failed or self.token != ord('?'):
            return cond
        self.advance()
        then_b = None
        else_b = None
        if self.token == ord(':'):
            self.advance()
            else_b = self.if_else()
        else:
            then_b = self.if_else()
            if not self.failed and self.token == ord(':'):
                self.advance()
                else_b = self.if_else()
        return ("IFELSE", cond, then_b, else_b)

    def expression(self):
        res = self.if_else()
        while not self.failed and self.token == ord(';'):
            self.advance()
            if not self.starts_expression(self.token):
                continue
            next_expr = self.if_else()
            if self.failed: return None
            res = ("JOIN", res, next_expr)
        return res

def test_code(code):
    print(f"\n--- Testing code: {code[:40]}... ---")
    endptr = 0
    while endptr < len(code):
        # single out top level segment as in nseel-compiler.c
        had_something = 0
        pcnt = 0
        pcnt2 = 0
        state = [0]
        expr_start = endptr
        while True:
            tok, next_p = nseel_simple_tokenizer(code, endptr, state)
            if not tok:
                break
            p_str = tok
            l = len(tok)
            endptr = next_p
            if p_str == ';':
                if had_something and not pcnt and not pcnt2:
                    break
            elif p_str[0] == '/' and l > 1 and p_str[1] in '/*':
                pass
            else:
                if not had_something:
                    expr_start = endptr - l
                    had_something = 1
                if p_str == '(': pcnt += 1
                elif p_str == ')': pcnt = max(0, pcnt - 1)
                elif p_str == '[': pcnt2 += 1
                elif p_str == ']': pcnt2 = max(0, pcnt2 - 1)
        if not had_something:
            break
        segment = code[expr_start:endptr]
        print(f"Segment: {segment.strip()}")
        lexer = Lexer(segment)
        parser = Parser(lexer)
        tree = parser.expression()
        if parser.failed or (parser.token != 0 and parser.token is not None):
            print(f"FAILED on segment: {segment} with token {parser.token}")
            return False
        else:
            print("OK")
    return True

# Test 1: Scientific notation
test_code("x = 1e-6;")

# Test 2: Standard biquad filter
test_code("""
srate = 44100;
w0 = 2 * $pi * 1000 / srate;
alpha = sin(w0) / (2 * 0.707);
b0 = (1 - cos(w0)) / 2;
b1 = 1 - cos(w0);
b2 = (1 - cos(w0)) / 2;
a0 = 1 + alpha;
a1 = -2 * cos(w0);
a2 = 1 - alpha;
""")

# Test 3: Ternary with blocks
test_code("""
out_mode == 0 ? (
    spl0 = mid_out;
    spl1 = sub_out;
) : (
    spl0 = sub_out;
    spl1 = mid_out;
);
""")

# Test 4: Trailing semicolons and empty parens
test_code("""
foo();
while (x < 10) (
    x += 1;
);
""")

# Test 5: Scientific notation variants and hex
test_code("""
x = 1e6;
y = 2.5e-3;
z = 1.0e+4;
a = 0.0001;
b = .5;
""")
