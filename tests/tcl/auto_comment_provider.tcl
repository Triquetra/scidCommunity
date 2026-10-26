# Copyright (C) 2025-2026 Hugh Whelan
# SPDX-License-Identifier: GPL-2.0-or-later
#
# auto_comment_provider.tcl -- Tk-free tests for the provider layer of
# tcl/tools/auto_comment.tcl.
#
#   tclsh tests/tcl/auto_comment_provider.tcl
#
# The transport, the URL joins, the auth decision and the reply/error parsing
# are pure functions once Tk is stubbed, so they can be checked without a
# display, a network or a model. Everything the dialogs add on top of them
# (packing, section switching, persistence) still needs one manual run.

set fails 0
set checks 0

proc check {label cond {detail ""}} {
    incr ::checks
    if {$cond} {
        puts "  ok   $label"
    } else {
        incr ::fails
        if {$detail eq ""} {
            puts "  FAIL $label"
        } else {
            puts "  FAIL $label -- $detail"
        }
    }
}

proc checkEq {label got want} {
    check $label [expr {$got eq $want}] "got '$got' want '$want'"
}

# --------------------------------------------------------------- environment --
# Stubs for the parts of scid that auto_comment.tcl touches at load time.
proc options.store {varname {default ""}} {
    if {![info exists $varname]} { set $varname $default }
}
namespace eval ttk {}
namespace eval ::auto_comment {}
proc winfo {args} { return 0 }
proc tk_messageBox {args} { return ok }
proc ttk::label {args} {}
proc ttk::labelframe {args} {}
proc ttk::entry {args} {}
proc ttk::button {args} {}
proc ttk::combobox {args} {}
proc ttk::frame {args} {}
proc ttk::checkbutton {args} {}
proc pack {args} {}
proc bind {args} {}
proc font {{args ""}} { return "" }
proc openURL {args} {}
set ::language E
set ::translatePieces 0

set root [file normalize [file join [file dirname [info script]] .. ..]]
source [file join $root tcl tools auto_comment.tcl]

# A temp directory of our own, so the request-file test never writes into the
# shared one. It lives in the OS temp directory, not in the source tree, so an
# aborted run cannot leave junk behind in the repository.
set sysTmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) \
              : [info exists ::env(TEMP)] ? $::env(TEMP) : "/tmp"}]
set tmproot [file join $sysTmp "auto_comment_test_[pid]"]
catch {file delete -force $tmproot}
file mkdir $tmproot
set ::env(TMPDIR) $tmproot

# ------------------------------------------------------------- provider list --
puts "\n== provider list =="
checkEq "all six providers" [::auto_comment::providerList] {none local openai opencode gemini deepseek}
check "none first so a fresh install sends nothing" \
    [expr {[lindex [::auto_comment::providerList] 0] eq "none"}]

# ----------------------------------------------------------------- readiness --
puts "\n== readiness =="
set ::auto_comment::provider none
checkEq "none is a refusal, not a failure" [::auto_comment::providerReady] {no model selected}

set ::auto_comment::provider opencode
set ::auto_comment::opencodeKey ""
set ::auto_comment::opencodeModel "glm-5.3-flash"
checkEq "opencode needs its key" [::auto_comment::providerReady] {no OpenCode key set}
set ::auto_comment::opencodeKey "k"
set ::auto_comment::opencodeModel ""
checkEq "opencode needs its model" [::auto_comment::providerReady] {no OpenCode model selected}
set ::auto_comment::opencodeModel "glm-5.3-flash"
checkEq "opencode ready" [::auto_comment::providerReady] {}

set ::auto_comment::provider local
set ::auto_comment::localUrl "http://localhost:11434"
set ::auto_comment::localModel ""
checkEq "local needs a model" [::auto_comment::providerReady] {no local model selected}
set ::auto_comment::localModel "qwen3:8b"
checkEq "local ready and needs no key" [::auto_comment::providerReady] {}

set ::auto_comment::provider openai
set ::auto_comment::openaiUrl "https://api.deepseek.com"
set ::auto_comment::openaiModel ""
checkEq "openai needs a model" [::auto_comment::providerReady] {no model selected}
set ::auto_comment::openaiModel "deepseek-v4-pro"
checkEq "openai ready without a key" [::auto_comment::providerReady] {}

set ::auto_comment::provider bogus
checkEq "unknown provider is named" [::auto_comment::providerReady] "unknown provider: bogus"

# ------------------------------------------------------------------ endpoints --
puts "\n== endpoint joins =="
set ::auto_comment::provider openai
foreach {label url want} {
    "bare host"        "https://api.deepseek.com"                       "https://api.deepseek.com/v1/chat/completions"
    "trailing slash"   "https://api.deepseek.com/"                      "https://api.deepseek.com/v1/chat/completions"
    "with /v1"         "https://api.openai.com/v1"                      "https://api.openai.com/v1/chat/completions"
    "with /v1/"        "https://api.openai.com/v1/"                     "https://api.openai.com/v1/chat/completions"
    "pasted full URL"  "https://api.deepseek.com/v1/chat/completions"   "https://api.deepseek.com/v1/chat/completions"
    "pasted full URL/" "https://api.deepseek.com/v1/chat/completions/"  "https://api.deepseek.com/v1/chat/completions"
    "gemini root"      "https://generativelanguage.googleapis.com/v1beta/openai" \
                       "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
    "gemini full"      "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions" \
                       "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
} {
    set ::auto_comment::openaiUrl $url
    checkEq "openai $label" [::auto_comment::chatEndpoint] $want
}

set ::auto_comment::provider opencode
checkEq "opencode endpoint" [::auto_comment::chatEndpoint] \
    {https://opencode.ai/inference/openai/v1/chat/completions}

set ::auto_comment::provider local
set ::auto_comment::localUrl "http://localhost:11434/"
checkEq "local endpoint" [::auto_comment::chatEndpoint] {http://localhost:11434/api/chat}

puts "\n== model-list URLs =="
foreach {label url want} {
    "bare host"       "https://api.deepseek.com"                     "https://api.deepseek.com/v1/models"
    "with /v1"        "https://api.openai.com/v1"                    "https://api.openai.com/v1/models"
    "pasted endpoint" "https://api.deepseek.com/v1/chat/completions" "https://api.deepseek.com/v1/models"
    "local style"     "http://localhost:8000/v1"                     "http://localhost:8000/v1/models"
    "gemini root"     "https://generativelanguage.googleapis.com/v1beta/openai" \
                      "https://generativelanguage.googleapis.com/v1beta/openai/models"
} {
    checkEq "models for $label" [::auto_comment::modelsUrl $url] $want
}

# -------------------------------------------------------------------- request --
puts "\n== request bodies =="
set ::auto_comment::provider opencode
set ::auto_comment::opencodeModel "glm-5.3-flash"
set body [::auto_comment::chatBody {Say "hi"} 600]
check "opencode sends its own model" [string match {*"model":"glm-5.3-flash"*} $body] $body
check "opencode uses max_tokens" [string match {*"max_tokens":600*} $body] $body
check "prompt quotes escaped" [expr {[string first {Say \"hi\"} $body] >= 0}] $body

set ::auto_comment::provider openai
set ::auto_comment::openaiModel "deepseek-v4-pro"
set body [::auto_comment::chatBody "x" 300]
check "openai sends its own model" [string match {*"model":"deepseek-v4-pro"*} $body] $body

set ::auto_comment::provider local
set ::auto_comment::localModel "qwen3:8b"
set body [::auto_comment::chatBody "x" 300]
check "local uses num_predict" [string match {*"num_predict":300*} $body] $body
check "local body has no max_tokens" [expr {![string match {*max_tokens*} $body]}] $body

set ::auto_comment::provider opencode
checkEq "providerModel follows the provider" [::auto_comment::providerModel] "glm-5.3-flash"

# ----------------------------------------------------------------------- auth --
puts "\n== auth =="
set ::auto_comment::provider opencode
set ::auto_comment::opencodeKey "oc-key"
checkEq "opencode sends its key" [::auto_comment::chatAuth] {Authorization: Bearer oc-key}

set ::auto_comment::provider openai
set ::auto_comment::openaiKey "sk-key"
set ::auto_comment::openaiUrl "https://api.openai.com/v1"
checkEq "openai over https" [::auto_comment::chatAuth] {Authorization: Bearer sk-key}
set ::auto_comment::openaiUrl "http://10.0.0.5:8000"
checkEq "openai key never over cleartext" [::auto_comment::chatAuth] {}
set ::auto_comment::openaiUrl "http://127.0.0.1:8000"
checkEq "openai key allowed to loopback" [::auto_comment::chatAuth] {Authorization: Bearer sk-key}

set ::auto_comment::provider local
set ::auto_comment::localUrl "http://localhost:11434"
set ::auto_comment::localModel "m"
checkEq "local is never sent the cloud key" [::auto_comment::chatAuth] {}

# the guard that queryChat applies only to the openai provider, exercised here
# in isolation so the test never shells out to curl
set ::auto_comment::openaiUrl "http://10.0.0.5:8000"
set ::auto_comment::openaiKey "sk-key"
check "cleartext refused for a remote http endpoint" \
    [expr {[::auto_comment::cleartextKeyError $::auto_comment::openaiUrl $::auto_comment::openaiKey] ne ""}]

# --------------------------------------------------------------------- replies --
puts "\n== replies and errors =="
set openaiReply {{"id":"x","choices":[{"index":0,"message":{"role":"assistant","content":"Rook takes e5."},"finish_reason":"stop"}]}}
checkEq "openai reply" [::auto_comment::replyText $openaiReply] {Rook takes e5.}

set ollamaReply {{"model":"m","message":{"role":"assistant","content":"Castle early."},"done":true}}
checkEq "ollama reply" [::auto_comment::replyText $ollamaReply] {Castle early.}

set reasoner {{"choices":[{"message":{"role":"assistant","reasoning_content":"thinking about the pawn structure","content":"The knight goes to f3."}}]}}
checkEq "reasoning is not the answer" [::auto_comment::replyText $reasoner] {The knight goes to f3.}

checkEq "escapes decoded" \
    [::auto_comment::replyText {{"choices":[{"message":{"content":"line1\nline2 \"q\" and \\ slash"}}]}}] \
    "line1\nline2 \"q\" and \\ slash"

checkEq "no error in a good reply" [::auto_comment::replyError $openaiReply] {}
checkEq "opencode auth error" \
    [::auto_comment::replyError {{"type":"error","error":{"type":"AuthError","message":"Missing API key."}}}] \
    {Missing API key.}
checkEq "deepseek error object" \
    [::auto_comment::replyError {{"error":{"message":"Insufficient Balance","type":"unknown_error"}}}] \
    {Insufficient Balance}
checkEq "bare string error" \
    [::auto_comment::replyError {{"error":"model not found"}}] {model not found}
check "unshaped error still explains itself" \
    [string match {API error:*} [::auto_comment::replyError {{"error":{"weird":true}}}]] \
    [::auto_comment::replyError {{"error":{"weird":true}}}]

checkEq "markdown stripped" \
    [::auto_comment::finishReply {{"choices":[{"message":{"content":"**Nf3** is best."}}]}}] \
    {Nf3 is best.}
checkEq "lowercase SAN repaired" \
    [::auto_comment::finishReply {{"choices":[{"message":{"content":"the knight goes nf3"}}]}}] \
    {the knight goes Nf3}

# ------------------------------------------------------- gateway model filter --
puts "\n== gateway model filter =="
set gatewayIds {glm-5.3 kimi-k3 minimax-m3 deepseek-v4-pro mistral-large-4 qwen3.8-max \
                gpt-6.1-sol claude-sonnet-5 gemini-3.6-flash grok-4.7 muse-spark-1.3 \
                jev-1.13 qwen3.6-plus glm-5.3-flash-free deepseek-v4.1-flash-free \
                big-pickle test}
checkEq "only chat-completions paid models survive" \
    [::auto_comment::chatCompletionsOnly $gatewayIds] \
    {glm-5.3 kimi-k3 minimax-m3 deepseek-v4-pro mistral-large-4 qwen3.8-max}
checkEq "an unknown new model is kept" \
    [::auto_comment::chatCompletionsOnly {brand-new-model}] {brand-new-model}

# ------------------------------------------------------------ request files --
puts "\n== request files =="
set f1 [::auto_comment::writeRequestFile {body one} chat]
set f2 [::auto_comment::writeRequestFile {body two} chat]
check "two calls never share a path" [expr {$f1 ne $f2}] "$f1 / $f2"
check "the body round-trips" [expr {[read [set fh [open $f1 r]]] eq "body one"}] "content"
close $fh
check "name is not predictable" [expr {[file tail $f1] ne "auto_comment_chat.json"}] [file tail $f1]
if {$::tcl_platform(platform) eq "windows"} {
    puts "  skip permissions are not a POSIX mode on this platform"
} else {
    file stat $f1 st
    checkEq "owner-only permissions" [format %04o [expr {$st(mode) & 0o777}]] 0600
}
file delete -force $f1 $f2

# ------------------------------------------------------------------- cleanup --
file delete -force $tmproot

puts "\n$checks checks, $fails failures"
exit [expr {$fails ? 1 : 0}]
