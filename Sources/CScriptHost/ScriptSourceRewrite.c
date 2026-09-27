#include "ScriptSourceRewrite.h"
#include <ctype.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct { const char* start; const char* end; bool identifier; } Token;
typedef struct { char* data; size_t size; size_t capacity; bool failed; } Buffer;

static void append(Buffer* buffer, const char* text, size_t length) {
    if (buffer->failed) return;
    if (length > SIZE_MAX - buffer->size - 1) { buffer->failed = true; return; }
    size_t needed = buffer->size + length + 1;
    if (needed > buffer->capacity) {
        char* next = realloc(buffer->data, needed);
        if (next == NULL) { buffer->failed = true; return; }
        buffer->data = next;
        buffer->capacity = needed;
    }
    memcpy(buffer->data + buffer->size, text, length);
    buffer->size += length;
    buffer->data[buffer->size] = '\0';
}

static void literal(Buffer* buffer, const char* text) { append(buffer, text, strlen(text)); }
static bool identifier_start(unsigned char c) { return isalpha(c) || c == '_' || c == '$' || c >= 128; }
static bool identifier_part(unsigned char c) { return identifier_start(c) || isdigit(c); }

// ECMAScript whitespace includes Unicode separators frequently introduced by
// copy/pasting editor scripts. Keep UTF-8 identifier bytes distinct from them.
static size_t space_length(const char* cursor) {
    const unsigned char* p = (const unsigned char*)cursor;
    if (*p && isspace(*p)) return 1;
    if (p[0] == 0xc2 && p[1] == 0xa0) return 2;
    if (p[0] == 0xe1 && p[1] == 0x9a && p[2] == 0x80) return 3;
    if (p[0] == 0xe2 && p[1] == 0x80 && ((p[2] >= 0x80 && p[2] <= 0x8a) || p[2] == 0xa8 || p[2] == 0xa9 || p[2] == 0xaf)) return 3;
    if (p[0] == 0xe2 && p[1] == 0x81 && p[2] == 0x9f) return 3;
    if (p[0] == 0xe3 && p[1] == 0x80 && p[2] == 0x80) return 3;
    if (p[0] == 0xef && p[1] == 0xbb && p[2] == 0xbf) return 3;
    return 0;
}

static size_t line_ending_length(const char* cursor) {
    const unsigned char* p = (const unsigned char*)cursor;
    if (*p == '\n' || *p == '\r') return 1;
    return p[0] == 0xe2 && p[1] == 0x80 && (p[2] == 0xa8 || p[2] == 0xa9) ? 3 : 0;
}
static bool equals(Token token, const char* value) {
    return (size_t)(token.end - token.start) == strlen(value) && strncmp(token.start, value, strlen(value)) == 0;
}

static const char* quoted_end(const char* cursor) {
    char quote = *cursor++;
    while (*cursor) {
        if (*cursor == '\\' && cursor[1]) { cursor += 2; continue; }
        if (quote == '`' && cursor[0] == '$' && cursor[1] == '{') {
            cursor += 2;
            int depth = 1;
            while (*cursor && depth > 0) {
                if (*cursor == '\'' || *cursor == '"' || *cursor == '`') { cursor = quoted_end(cursor); continue; }
                if (cursor[0] == '/' && cursor[1] == '/') { while (*cursor && !line_ending_length(cursor)) cursor++; continue; }
                if (cursor[0] == '/' && cursor[1] == '*') {
                    cursor += 2;
                    while (*cursor && !(cursor[0] == '*' && cursor[1] == '/')) cursor++;
                    if (*cursor) cursor += 2;
                    continue;
                }
                if (*cursor == '{') depth++;
                if (*cursor == '}') depth--;
                cursor++;
            }
            continue;
        }
        if (*cursor++ == quote) break;
    }
    return cursor;
}

static Token next_token(const char** position) {
    const char* cursor = *position;
    while (*cursor) {
        size_t whitespace = space_length(cursor);
        if (whitespace) { cursor += whitespace; continue; }
        if (cursor[0] == '/' && cursor[1] == '/') {
            while (*cursor && !line_ending_length(cursor)) cursor++;
            continue;
        }
        if (cursor[0] == '/' && cursor[1] == '*') {
            cursor += 2;
            while (*cursor && !(cursor[0] == '*' && cursor[1] == '/')) cursor++;
            if (*cursor) cursor += 2;
            continue;
        }
        break;
    }
    Token token = {cursor, cursor, identifier_start((unsigned char)*cursor)};
    if (*cursor == '\'' || *cursor == '"' || *cursor == '`') cursor = quoted_end(cursor);
    else if (token.identifier) { while (identifier_part((unsigned char)*cursor) && !space_length(cursor)) cursor++; }
    else if (*cursor) cursor++;
    token.end = cursor;
    *position = cursor;
    return token;
}

// Host initialization must preserve the directive prologue of the rewritten
// body. Comments and additional string directives may precede "use strict".
bool we_script_source_is_strict(const char* source) {
    const char* cursor = source != NULL ? source : "";
    for (;;) {
        Token directive = next_token(&cursor);
        if (*directive.start != '\'' && *directive.start != '"') return false;
        const char* after_literal = cursor;
        Token next = next_token(&cursor);
        if (!equals(next, ";") && next.start != next.end) {
            bool newline = false;
            for (const char* p = after_literal; p < next.start; p++) {
                if (line_ending_length(p)) newline = true;
            }
            // These tokens can continue a string expression across a newline.
            if (!newline || strchr("([.+-*/%?`,<>=!&|^", *next.start) != NULL) return false;
            cursor = after_literal;
        }
        if (equals(directive, "'use strict'") || equals(directive, "\"use strict\"")) return true;
        if (next.start == next.end) return false;
    }
}

static void assign_import(Buffer* output, Token local, Token module, Token member) {
    literal(output, "var ");
    append(output, local.start, local.end - local.start);
    literal(output, " = __weImportModule(");
    append(output, module.start, module.end - module.start);
    literal(output, ")");
    if (member.start != NULL) {
        literal(output, ".");
        append(output, member.start, member.end - member.start);
    }
    literal(output, ";");
}

// Imports are grammar-delimited, so a declaration can cross lines or share a
// line with other statements. Return NULL without rewriting unknown syntax.
static const char* rewrite_import(const char* cursor, Buffer* output) {
    Token first = next_token(&cursor);
    if (*first.start == '\'' || *first.start == '"') {
        literal(output, "__weImportModule("); append(output, first.start, first.end - first.start); literal(output, ");");
        return cursor;
    }
    Token locals[128], members[128];
    size_t count = 0;
    Token module = {0};
    if (equals(first, "*")) {
        if (!equals(next_token(&cursor), "as")) return NULL;
        Token local = next_token(&cursor);
        if (!local.identifier || !equals(next_token(&cursor), "from")) return NULL;
        module = next_token(&cursor);
        if (*module.start != '\'' && *module.start != '"') return NULL;
        assign_import(output, local, module, (Token){0});
    } else if (equals(first, "{")) {
        Token member = next_token(&cursor);
        while (!equals(member, "}")) {
            if (!member.identifier || count == 128) return NULL;
            Token local = member;
            Token separator = next_token(&cursor);
            if (equals(separator, "as")) {
                local = next_token(&cursor);
                if (!local.identifier) return NULL;
                separator = next_token(&cursor);
            }
            locals[count] = local; members[count++] = member;
            if (equals(separator, "}")) break;
            if (!equals(separator, ",")) return NULL;
            member = next_token(&cursor);
        }
        if (!equals(next_token(&cursor), "from")) return NULL;
        module = next_token(&cursor);
        if (*module.start != '\'' && *module.start != '"') return NULL;
        // Even an empty import list resolves/validates its module.
        if (count == 0) { literal(output, "__weImportModule("); append(output, module.start, module.end - module.start); literal(output, ");"); }
        for (size_t i = 0; i < count; i++) assign_import(output, locals[i], module, members[i]);
    } else { return NULL; }
    return cursor;
}

char* we_rewrite_script_source(const char* source) {
    if (source == NULL) source = "";
    Buffer output = {0};
    Buffer imports = {0};
    const char* copied = source;
    const char* cursor = source;
    int depth = 0;
    bool can_regex = true;
    while (*cursor) {
        Token token = next_token(&cursor);
        if (token.start == token.end) break;
        if (equals(token, "/") && can_regex) {
            bool character_class = false;
            while (*cursor && !line_ending_length(cursor)) {
                if (*cursor == '\\' && cursor[1]) { cursor += 2; continue; }
                if (*cursor == '[') character_class = true;
                if (*cursor == ']') character_class = false;
                if (*cursor++ == '/' && !character_class) break;
            }
            while (identifier_part((unsigned char)*cursor) && !space_length(cursor)) cursor++;
            can_regex = false;
            continue;
        }
        if (depth == 0 && equals(token, "import")) {
            Buffer replacement = {0};
            const char* end = rewrite_import(cursor, &replacement);
            if (end != NULL) {
                append(&output, copied, token.start - copied);
                if (replacement.failed) output.failed = true;
                else append(&imports, replacement.data, replacement.size);
                // Preserve line breaks and statement boundaries in the body.
                for (const char* p = token.start; p < end;) {
                    size_t newline = line_ending_length(p);
                    if (newline) { append(&output, p, newline); p += newline; }
                    else { literal(&output, " "); p++; }
                }
                copied = cursor = end;
            }
            free(replacement.data);
        } else if (depth == 0 && equals(token, "export")) {
            const char* peek = cursor;
            Token declaration = next_token(&peek);
            if (equals(declaration, "function") || equals(declaration, "async") || equals(declaration, "const") || equals(declaration, "let") || equals(declaration, "var") || equals(declaration, "class")) {
                append(&output, copied, token.start - copied);
                literal(&output, "      ");
                copied = token.end;
            }
        }
        if (equals(token, "{") || equals(token, "[") || equals(token, "(")) depth++;
        if (equals(token, "}") || equals(token, "]") || equals(token, ")")) depth--;
        can_regex = token.identifier ? (equals(token, "return") || equals(token, "throw"))
            : token.end - token.start == 1 && strchr("=(:,;[!+-*?{", *token.start) != NULL;
    }
    append(&output, copied, strlen(copied));
    if (output.failed || imports.failed) { free(output.data); free(imports.data); return NULL; }
    append(&imports, output.data, output.size);
    free(output.data);
    if (imports.failed) { free(imports.data); return NULL; }
    return imports.data;
}
