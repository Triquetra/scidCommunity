# Copyright (C) 2025-2026 Hugh Whelan
# SPDX-License-Identifier: GPL-2.0-or-later

############################################################
### Auto Comment - AI-generated chess commentary
### Queries engine evaluation APIs and uses an LLM (Gemini,
### DeepSeek, an OpenAI-compatible endpoint, a local model,
### or OpenCode Console) to generate natural language
### commentary.

namespace eval ::auto_comment {
    # LLM provider, one value for every path:
    #   none    no model at all - no request is ever made
    #   local   any Ollama-style server (ollama, LM Studio's Ollama endpoint)
    #   openai  any OpenAI-compatible endpoint: DeepSeek, Gemini's compatibility
    #           endpoint, vLLM, LM Studio, a gateway...
    #   opencode OpenCode Console's model gateway, which is OpenAI-compatible
    #   gemini  Google's native API   (kept until Game Comment is retired)
    #   deepseek DeepSeek's native API (kept until Game Comment is retired)
    # The default is "none": a review is complete without prose, and a machine
    # with no model should behave exactly like one whose owner has not chosen a
    # model yet. Nothing is sent anywhere until someone picks a provider, and an
    # existing install keeps whatever it already stored.
    options.store ::auto_comment::provider "none"

    # Local (Ollama-style) settings
    options.store ::auto_comment::localUrl "http://localhost:11434"
    options.store ::auto_comment::localModel ""

    # OpenAI-compatible settings
    options.store ::auto_comment::openaiUrl "https://api.deepseek.com"
    options.store ::auto_comment::openaiKey ""
    options.store ::auto_comment::openaiModel ""

    # OpenCode Console settings. The gateway itself is a commercial service, so
    # both roots live here where a rename or a path change is one line.
    # Its model list is a sibling of the chat root, not a child of it:
    # .../inference/v1/models answers, .../inference/openai/v1/models does not.
    options.store ::auto_comment::opencodeKey ""
    options.store ::auto_comment::opencodeModel ""
    variable opencodeBase      "https://opencode.ai/inference/openai"
    variable opencodeModelsUrl "https://opencode.ai/inference/v1/models"

    # Gemini settings
    options.store ::auto_comment::apiKey ""
    options.store ::auto_comment::model "gemini-3.6-flash"

    # DeepSeek settings
    options.store ::auto_comment::deepseekApiKey ""
    options.store ::auto_comment::deepseekModel "deepseek-v4-pro"

    variable geminiApiBase "https://generativelanguage.googleapis.com/v1beta/models"
    variable deepseekApiBase "https://api.deepseek.com"
    variable lichessApiUrl "https://lichess.org/api/cloud-eval"
    variable chessdbApiUrl "http://www.chessdb.cn/cdb.php"
    
    # Log file for Windows GUI (fallback when stderr unavailable)
    variable logFile ""

    # Debug logging is opt-in: release builds must not write to stderr/stdout
    # (a stray console can break the Windows GUI build). Set the
    # SCID_AUTOCOMMENT_DEBUG environment variable to enable it when developing.
    variable debugEnabled [expr {[info exists ::env(SCID_AUTOCOMMENT_DEBUG)] ? 1 : 0}]
}

# ::auto_comment::logDebug
#   Writes debug messages to stderr (Linux/macOS) or a log file (Windows GUI).
#   Does nothing unless debug logging has been enabled (see debugEnabled).
#
proc ::auto_comment::logDebug {message} {
    variable debugEnabled
    variable logFile

    if {![info exists debugEnabled] || !$debugEnabled} { return }

    # Try stderr first (works on Linux/macOS terminal)
    if {[catch {puts stderr $message}]} {
        # Fallback: write to a log file (for Windows GUI)
        if {$logFile eq ""} {
            set logDir [file join [pwd] "logs"]
            catch {file mkdir $logDir}
            set logFile [file join $logDir "auto_comment_debug.log"]
        }
        set fd [open $logFile "a"]
        puts $fd $message
        close $fd
    } else {
        flush stderr
    }
}

# ::auto_comment::fitWindow
#   Sizes a toplevel window to fit its content and centers it on screen.
#   Wayland/Hyprland (via XWayland) does not reliably honor the requested
#   size of a Tk toplevel, which leaves popups clipped. Explicitly setting
#   the geometry ensures the whole popup is visible. Optional minimum
#   width/height can be supplied for windows with a preferred floor size.
#
proc ::auto_comment::fitWindow {w {minW 0} {minH 0}} {
    if {![winfo exists $w]} { return }
    update idletasks
    set reqW [winfo reqwidth $w]
    set reqH [winfo reqheight $w]
    if {$reqW < $minW} { set reqW $minW }
    if {$reqH < $minH} { set reqH $minH }

    # Keep the window on screen (leave a small margin).
    set screenW [winfo screenwidth $w]
    set screenH [winfo screenheight $w]
    set maxW [expr {$screenW - 40}]
    set maxH [expr {$screenH - 80}]
    if {$maxW < 200} { set maxW 200 }
    if {$maxH < 100} { set maxH 100 }
    if {$reqW > $maxW} { set reqW $maxW }
    if {$reqH > $maxH} { set reqH $maxH }

    set x [expr {($screenW - $reqW) / 2}]
    set y [expr {($screenH - $reqH) / 2}]
    if {$x < 0} { set x 0 }
    if {$y < 0} { set y 0 }

    wm geometry $w "${reqW}x${reqH}+${x}+${y}"
}

# ::auto_comment::providerList
#   The values the settings combo offers, in the order it shows them.
proc ::auto_comment::providerList {} {
    return {none local openai opencode gemini deepseek}
}

# ::auto_comment::providerReady
#   Empty when the selected provider has what it needs, otherwise the reason it
#   cannot run - shown to the user instead of a request that silently fails.
proc ::auto_comment::providerReady {} {
    switch -- $::auto_comment::provider {
        none     { return "no model selected" }
        local {
            if {$::auto_comment::localUrl eq ""} { return "no local endpoint set" }
            if {$::auto_comment::localModel eq ""} { return "no local model selected" }
            return ""
        }
        openai {
            if {$::auto_comment::openaiUrl eq ""} { return "no endpoint set" }
            if {$::auto_comment::openaiModel eq ""} { return "no model selected" }
            return ""
        }
        opencode {
            # the gateway requires the header for every paid model, so a missing
            # key is a refusal here rather than a 401 from the endpoint
            if {$::auto_comment::opencodeKey eq ""} { return "no OpenCode key set" }
            if {$::auto_comment::opencodeModel eq ""} { return "no OpenCode model selected" }
            return ""
        }
        gemini {
            if {$::auto_comment::apiKey eq ""} { return "no Gemini key set" }
            if {$::auto_comment::model eq ""} { return "no Gemini model selected" }
            return ""
        }
        deepseek {
            if {$::auto_comment::deepseekApiKey eq ""} { return "no DeepSeek key set" }
            if {$::auto_comment::deepseekModel eq ""} { return "no DeepSeek model selected" }
            return ""
        }
    }
    return "unknown provider: $::auto_comment::provider"
}

# ::auto_comment::baseUrl
#   Normalise an API base the user typed. Both forms of the same endpoint are
#   accepted - "https://api.openai.com" and "https://api.openai.com/v1" - so a
#   caller can always append its own "/v1/..." path without doubling the version
#   segment. Trailing slashes are dropped too.
proc ::auto_comment::baseUrl {url} {
    set base [string trim [string trimright $url /]]
    regsub -nocase {/v1$} $base "" base
    return [string trimright $base /]
}

# ::auto_comment::urlHost
#   The host of an http(s) URL, without userinfo, port or brackets. "" when the
#   string is not an absolute URL.
proc ::auto_comment::urlHost {url} {
    if {![regexp -nocase {^[a-z][a-z0-9+.-]*://([^/?#]*)} [string trim $url] -> auth]} {
        return ""
    }
    set auth [string range $auth [expr {[string last "@" $auth] + 1}] end]
    if {[string match {\[*} $auth]} {
        return [string range $auth 0 [string first "\]" $auth]]
    }
    return [lindex [split $auth ":"] 0]
}

# ::auto_comment::isLoopbackHost
#   True for a host that never leaves this machine. vLLM and LM Studio answer on
#   http://localhost:8000, so loopback is the one place a cleartext request is
#   not a leak.
proc ::auto_comment::isLoopbackHost {host} {
    set h [string tolower [string trim $host]]
    if {[string match {\[*} $h]} { set h [string range $h 1 end-1] }
    if {$h in {localhost 127.0.0.1 ::1}} { return 1 }
    return [regexp {^127\.[0-9]+\.[0-9]+\.[0-9]+$} $h]
}

# ::auto_comment::cleartextKeyError
#   "" when it is safe to send an API key to $url, otherwise the reason to
#   refuse. A key over http to a remote host would go out in clear text; the
#   endpoint may still be used without a key (the dialog says to leave it empty
#   when the endpoint needs none).
proc ::auto_comment::cleartextKeyError {url key} {
    if {$key eq ""} { return "" }
    if {[regexp -nocase {^https://} [string trim $url]]} { return "" }
    if {[::auto_comment::isLoopbackHost [::auto_comment::urlHost $url]]} { return "" }
    return "refusing to send the API key in clear text to \"$url\": use https, or clear the key when the endpoint needs none"
}

# ::auto_comment::writeRequestFile
#   Write a request body to a fresh file and return its path. The name is
#   unpredictable and the file is created exclusively and owner-only, so neither
#   a pre-created file or symlink nor another local account can reach the body:
#   it carries the prompt, and the prompt carries game data.
proc ::auto_comment::writeRequestFile {body {tag chat}} {
    set dir [::auto_comment::getTempDir]
    for {set attempt 0} {$attempt < 10} {incr attempt} {
        set name "auto_comment_${tag}_[pid]_[clock seconds]_[clock clicks]_[expr {int(rand() * 1000000)}].json"
        set path [file join $dir $name]
        # EXCL prevents substitution, 0600 prevents reading: a shared /tmp uses
        # 0644 by default, which is world-readable while curl runs.
        if {[catch {set fd [open $path {WRONLY CREAT EXCL} 0600]}]} { continue }
        if {[catch {
            puts -nonewline $fd $body
            close $fd
        } err]} {
            catch {close $fd}
            catch {file delete -force $path}
            return -code error $err
        }
        return $path
    }
    return -code error "cannot create a request file in $dir"
}

# ::auto_comment::chatEndpoint
#   The URL a chat request goes to for the selected provider.
proc ::auto_comment::chatEndpoint {} {
    switch -- $::auto_comment::provider {
        local  { return "[::auto_comment::baseUrl $::auto_comment::localUrl]/api/chat" }
        openai {
            set base [::auto_comment::baseUrl $::auto_comment::openaiUrl]
            # A full endpoint pasted from a provider's documentation is used as
            # it stands. Appending the path to it again is the classic 404, and
            # copying the endpoint is what people do.
            if {[string match -nocase */chat/completions $base]} { return $base }
            # Gemini's compatibility root carries its own version segment, so it
            # takes the path without the leading /v1.
            if {[string match -nocase */v1beta/openai $base]} { return "$base/chat/completions" }
            return "$base/v1/chat/completions"
        }
        opencode { return "$::auto_comment::opencodeBase/v1/chat/completions" }
    }
    return ""
}

# ::auto_comment::modelsUrl
#   The model-list URL that belongs to a chat base. Accepts the same forms as
#   chatEndpoint - a base with or without /v1, or the full endpoint, which is
#   what gets pasted - and keeps Gemini's compatibility root on its own version
#   segment, because /v1/models does not exist below it.
proc ::auto_comment::modelsUrl {url} {
    set base [string trim $url]
    regsub -nocase {/chat/completions$} $base "" base
    set base [::auto_comment::baseUrl $base]
    if {[string match -nocase */v1beta/openai $base]} { return "$base/models" }
    return "$base/v1/models"
}

# ::auto_comment::providerModel
#   The model id for the selected chat provider. Each generic provider keeps its
#   own model, so switching channels does not overwrite the other one's choice.
proc ::auto_comment::providerModel {} {
    switch -- $::auto_comment::provider {
        local    { return $::auto_comment::localModel }
        openai   { return $::auto_comment::openaiModel }
        opencode { return $::auto_comment::opencodeModel }
    }
    return ""
}

# ::auto_comment::chatBody
#   The request body for the selected provider. Ollama's native API takes
#   "options num_predict"; OpenAI-compatible ones take "max_tokens". Both take a
#   single user message.
proc ::auto_comment::chatBody {prompt {maxTokens 300}} {
    set esc [::auto_comment::escapeJson $prompt]
    switch -- $::auto_comment::provider {
        local {
            set model [::auto_comment::escapeJson $::auto_comment::localModel]
            return "{\"model\":\"$model\",\"messages\":\[{\"role\":\"user\",\"content\":\"$esc\"}\],\"stream\":false,\"options\":{\"num_predict\":$maxTokens}}"
        }
        openai -
        opencode {
            set model [::auto_comment::escapeJson [::auto_comment::providerModel]]
            return "{\"model\":\"$model\",\"messages\":\[{\"role\":\"user\",\"content\":\"$esc\"}\],\"stream\":false,\"max_tokens\":$maxTokens}"
        }
    }
    return ""
}

# ::auto_comment::chatAuth
#   The Authorization header value, or "" when the endpoint needs no key. A local
#   server must never be sent someone's cloud key.
proc ::auto_comment::chatAuth {} {
    switch -- $::auto_comment::provider {
        opencode {
            if {$::auto_comment::opencodeKey eq ""} { return "" }
            # the OpenCode endpoint is always https, so no cleartext case exists
            return "Authorization: Bearer $::auto_comment::opencodeKey"
        }
        openai {
            if {$::auto_comment::openaiKey eq ""} { return "" }
            # queryChat refuses this case before it gets here; keeping the check
            # means a future caller cannot send the key over cleartext either.
            if {[::auto_comment::cleartextKeyError $::auto_comment::openaiUrl $::auto_comment::openaiKey] ne ""} {
                return ""
            }
            return "Authorization: Bearer $::auto_comment::openaiKey"
        }
    }
    return ""
}

# ::auto_comment::replyText
#   Pull the assistant text out of a chat response. OpenAI-compatible endpoints
#   answer in choices[0].message.content; Ollama in message.content. Both are
#   read here so the caller does not care which provider produced the reply.
proc ::auto_comment::replyText {raw} {
    set text [::auto_comment::extractOpenAIChoice $raw]
    if {$text eq ""} { set text [::auto_comment::extractOllamaMessage $raw] }
    return $text
}

proc ::auto_comment::extractOpenAIChoice {raw} {
    if {![regexp {"choices"\s*:\s*\[} $raw]} { return "" }
    if {[regexp {"content"\s*:\s*"((?:[^"\\]|\\.)*)"} $raw -> text]} {
        return [::auto_comment::unescapeJson $text]
    }
    return ""
}

proc ::auto_comment::extractOllamaMessage {raw} {
    if {![regexp {"message"\s*:\s*\{.*?"content"\s*:\s*"((?:[^"\\]|\\.)*)"} $raw -> text]} {
        return ""
    }
    return [::auto_comment::unescapeJson $text]
}

# ::auto_comment::unescapeJson
#   Minimal JSON string decoder: the escapes a chat reply actually contains.
proc ::auto_comment::unescapeJson {text} {
    return [subst -nocommands -novariables [string map [list {\\n} "\n" {\\t} "\t" {\\r} "\r" {\\\"} {"} {\\\\} {\\}] $text]]
}

# ::auto_comment::replyError
#   The message inside an API error response, or "" when the body is not one.
#   OpenAI-compatible endpoints put the text in error.message; the OpenCode
#   gateway wraps the same object one level deeper, and a few endpoints answer
#   with a bare string. The text is what the user needs: a missing key, a model
#   that is on another API, an unpaid plan.
proc ::auto_comment::replyError {raw} {
    if {[regexp {"error"\s*:\s*\{} $raw]} {
        if {[regexp {"message"\s*:\s*"((?:[^"\\]|\\.)*)"} $raw -> msg]} {
            return [::auto_comment::unescapeJson $msg]
        }
        return "API error: [string range [string trim $raw] 0 300]"
    }
    if {[regexp {"error"\s*:\s*"((?:[^"\\]|\\.)*)"} $raw -> msg]} {
        return [::auto_comment::unescapeJson $msg]
    }
    return ""
}

# ::auto_comment::query
#   One entry point for every caller. Returns the assistant text, or a string
#   starting with "ERROR:" that the caller shows to the user. "none" is a
#   refusal, not a failure: nothing is sent, and the caller is expected to have
#   offered the user a way to turn the coach on.
proc ::auto_comment::query {prompt {maxTokens 300}} {
    switch -- $::auto_comment::provider {
        none     { return "ERROR: no model selected (open Game Comment and press Settings...)" }
        gemini   { return [::auto_comment::queryGemini $prompt] }
        deepseek { return [::auto_comment::queryDeepSeek $prompt] }
        local -
        openai -
        opencode { return [::auto_comment::queryChat $prompt $maxTokens] }
    }
    return "ERROR: unknown provider: $::auto_comment::provider"
}

# ::auto_comment::queryChat
#   The transport for both generic providers: one request shape per provider,
#   written to a temp file and handed to curl, exactly like the native DeepSeek
#   path so Windows (curl.exe) and Unix behave the same.
proc ::auto_comment::queryChat {prompt {maxTokens 300}} {
    set reason [::auto_comment::providerReady]
    if {$reason ne ""} { return "ERROR: $reason" }
    # Only the OpenAI-compatible channel sends a user key to a user-typed URL.
    # Gating on the provider keeps unrelated saved settings from rejecting a
    # local request the user never pointed at that endpoint.
    if {$::auto_comment::provider eq "openai"} {
        set refuse [::auto_comment::cleartextKeyError $::auto_comment::openaiUrl $::auto_comment::openaiKey]
        if {$refuse ne ""} { return "ERROR: $refuse" }
    }
    set url [::auto_comment::chatEndpoint]
    set body [::auto_comment::chatBody $prompt $maxTokens]

    if {[catch {set tmpfile [::auto_comment::writeRequestFile $body chat]} err]} {
        return "ERROR: cannot write the request: $err"
    }

    set args [list curl -s --connect-timeout 15 --max-time 180 \
        -H {Content-Type: application/json} -X POST --data-binary @$tmpfile]
    set auth [::auto_comment::chatAuth]
    if {$auth ne ""} { lappend args -H $auth }
    lappend args $url

    set result ""
    set ok 0
    if {![catch {exec {*}$args 2>@1} result]} { set ok 1 }
    catch { file delete -force $tmpfile }
    if {!$ok} {
        return "ERROR: request failed (network error or timeout): [string range [string trim $result] 0 300]"
    }
    set err [::auto_comment::replyError $result]
    if {$err ne ""} { return "ERROR: $err" }
    set text [::auto_comment::finishReply $result]
    if {$text eq ""} {
        return "ERROR: the endpoint returned no text (check the model name)"
    }
    return $text
}

# ::auto_comment::finishReply
#   Turn a raw response into the text a caller writes: extract it, then apply the
#   same normalisation the native providers use. The prompt asks for plain text;
#   a model that ignores that must not be able to put "nf3" or "**bold**" into
#   the PGN.
proc ::auto_comment::finishReply {raw} {
    return [string trim [::auto_comment::cleanupText [::auto_comment::replyText $raw]]]
}

# ::auto_comment::modelChoices
#   Returns the fallback list of model ids for the given provider.  These are
#   only defaults; the "Load Models" button replaces them with the live list
#   retrieved from the provider.
#
proc ::auto_comment::modelChoices {provider} {
    switch -- $provider {
        deepseek { return {deepseek-v4-pro deepseek-flash} }
        gemini {
            return {gemini-3.6-flash gemini-3.5-flash-lite gemini-2.5-flash gemini-2.5-flash-lite}
        }
        opencode {
            # Chat-completions models the gateway serves to other clients. GPT
            # and Grok are Responses, Claude and most Qwen are Messages, Jev is
            # SystemOne, and the free tier answers OpenCode itself (403 here):
            # listing any of those would only produce a failed request. "Load
            # Models" asks the gateway and filters the same way.
            return {glm-5.3-flash deepseek-v4.1-flash minimax-m3 kimi-k2.6 mistral-large-4}
        }
    }
    # local and openai list what the endpoint reports; nothing is guessed
    return {}
}

# ::auto_comment::syncModelCombo
#   Points a model combobox at the model variable of the currently selected
#   provider and refreshes its choices, so the user can pick the model every
#   time the Game Comment dialog is opened.
#
proc ::auto_comment::syncModelCombo {combo} {
    if {![winfo exists $combo]} { return }
    switch -- $::auto_comment::provider {
        local    { set var ::auto_comment::localModel }
        openai   { set var ::auto_comment::openaiModel }
        opencode { set var ::auto_comment::opencodeModel }
        deepseek { set var ::auto_comment::deepseekModel }
        default  { set var ::auto_comment::model }
    }
    $combo configure -textvariable $var \
        -values [::auto_comment::modelChoices $::auto_comment::provider]
}

# ::auto_comment::openSettings
#   Opens the settings dialog and, once it is closed, refreshes the supplied
#   model combobox in case the provider or model was changed there.
#
proc ::auto_comment::openSettings {combo} {
    ::auto_comment::configureApiKey
    if {[winfo exists .autoCommentConfig]} {
        bind .autoCommentConfig <Destroy> \
            "+if {![winfo exists .autoCommentConfig]} { ::auto_comment::syncModelCombo $combo }"
    }
}

# ::auto_comment::syncProviderSections
#   Show only the section that belongs to the selected provider. Five sets of
#   fields packed at once is unreadable, and the dialog is the only place a user
#   finds out that a local model needs no key.
proc ::auto_comment::syncProviderSections {w} {
    if {![winfo exists $w.content]} { return }
    set want $::auto_comment::provider
    if {$want ni {none local openai opencode gemini deepseek}} { set want none }
    foreach name {note local openai opencode gemini deepseek} {
        set frame $w.content.$name
        if {![winfo exists $frame]} { continue }
        if {$name eq $want} {
            # Plain pack, no -before: every section is a child of $w.content, which
            # is itself packed above $w.buttons, so the order inside the content
            # frame is all that matters - and Tk refuses -before across masters.
            pack $frame -fill x -pady {0 10}
        } else {
            pack forget $frame
        }
    }
}

# ::auto_comment::configureApiKey
#   Dialog to configure LLM provider and API keys.
#
proc ::auto_comment::configureApiKey {} {
    set w .autoCommentConfig
    if {[winfo exists $w]} {
        raise $w
        return
    }

    toplevel $w
    wm title $w "Auto Comment - Settings"
    wm resizable $w 1 1
    wm minsize $w 320 200

    ttk::frame $w.content -padding 15
    pack $w.content -fill both -expand 1

    ttk::label $w.content.info -text \
        "Configure your LLM provider and API key(s).\nKeys are stored locally on your machine only.\nOK saves these settings to your options file." \
        -wraplength 420 -justify left
    pack $w.content.info -anchor w -pady {0 10}

    # Provider selector
    ttk::label $w.content.provlbl -text "LLM Provider:"
    pack $w.content.provlbl -anchor w
    ttk::combobox $w.content.provider -textvariable ::auto_comment::provider \
        -values [::auto_comment::providerList] -state readonly -width 18
    pack $w.content.provider -anchor w -pady {0 10}
    bind $w.content.provider <<ComboboxSelected>> \
        [list ::auto_comment::syncProviderSections $w]

    # --- none ---
    ttk::label $w.content.note -justify left -wraplength 420 -text \
        "No model selected.\nGame comments are written without AI prose; the review itself still runs."

    # --- Local (Ollama-style) ---
    ttk::labelframe $w.content.local -text "Local model" -padding 10
    ttk::label $w.content.local.urllbl -text "Endpoint:"
    pack $w.content.local.urllbl -anchor w
    ttk::entry $w.content.local.url -width 50 -textvariable ::auto_comment::localUrl
    pack $w.content.local.url -fill x -pady {0 5}
    ttk::label $w.content.local.modellbl -text "Model:"
    pack $w.content.local.modellbl -anchor w
    ttk::combobox $w.content.local.model -width 30 -textvariable ::auto_comment::localModel \
        -values [::auto_comment::modelChoices local]
    pack $w.content.local.model -anchor w -pady {0 5}
    ttk::button $w.content.local.load -text "Load Models" \
        -command [list ::auto_comment::loadModels $w.content.local.model local]
    pack $w.content.local.load -anchor w -pady {0 5}
    ttk::label $w.content.local.hint -justify left -wraplength 420 -text \
        "Works with Ollama, LM Studio and any server that answers /api/chat. No key and no GPU required: a small model is enough."
    pack $w.content.local.hint -anchor w

    # --- OpenAI-compatible ---
    ttk::labelframe $w.content.openai -text "Cloud / OpenAI-compatible" -padding 10
    ttk::label $w.content.openai.urllbl -text "Endpoint:"
    pack $w.content.openai.urllbl -anchor w
    ttk::entry $w.content.openai.url -width 50 -textvariable ::auto_comment::openaiUrl
    pack $w.content.openai.url -fill x -pady {0 5}
    ttk::label $w.content.openai.keylbl -text "API key (leave empty if the endpoint needs none):"
    pack $w.content.openai.keylbl -anchor w
    ttk::entry $w.content.openai.key -width 50 -textvariable ::auto_comment::openaiKey -show "*"
    pack $w.content.openai.key -fill x -pady {0 5}
    ttk::label $w.content.openai.modellbl -text "Model:"
    pack $w.content.openai.modellbl -anchor w
    ttk::combobox $w.content.openai.model -width 30 -textvariable ::auto_comment::openaiModel \
        -values [::auto_comment::modelChoices openai]
    pack $w.content.openai.model -anchor w -pady {0 5}
    ttk::button $w.content.openai.load -text "Load Models" \
        -command [list ::auto_comment::loadModels $w.content.openai.model openai]
    pack $w.content.openai.load -anchor w -pady {0 5}
    ttk::label $w.content.openai.hint -justify left -wraplength 420 -text \
        "DeepSeek, Gemini's compatibility endpoint, vLLM, a gateway: anything that speaks /v1/chat/completions. Either the base URL or the full endpoint can be pasted."
    pack $w.content.openai.hint -anchor w

    # --- OpenCode Console ---
    ttk::labelframe $w.content.opencode -text "OpenCode Console" -padding 10
    ttk::label $w.content.opencode.keylbl -text "API key:"
    pack $w.content.opencode.keylbl -anchor w
    ttk::entry $w.content.opencode.key -width 50 -textvariable ::auto_comment::opencodeKey -show "*"
    pack $w.content.opencode.key -fill x -pady {0 5}
    ttk::label $w.content.opencode.modellbl -text "Model:"
    pack $w.content.opencode.modellbl -anchor w
    ttk::combobox $w.content.opencode.model -width 30 -textvariable ::auto_comment::opencodeModel \
        -values [::auto_comment::modelChoices opencode]
    pack $w.content.opencode.model -anchor w -pady {0 5}
    ttk::button $w.content.opencode.load -text "Load Models" \
        -command [list ::auto_comment::loadModels $w.content.opencode.model opencode]
    pack $w.content.opencode.load -anchor w -pady {0 5}
    ttk::button $w.content.opencode.open -text "Get an API Key" -command {
        openURL "https://opencode.ai/console"
    }
    pack $w.content.opencode.open -anchor w -pady {0 5}
    ttk::label $w.content.opencode.hint -justify left -wraplength 420 -text \
        "OpenCode's model gateway: paid models or a Go plan. Free models only answer OpenCode itself, so they are not listed. Only chat-completions models work here; copy any other model id from the console."
    pack $w.content.opencode.hint -anchor w

    # --- Gemini section ---
    ttk::labelframe $w.content.gemini -text "Google Gemini" -padding 10
    pack $w.content.gemini -fill x -pady {0 10}

    ttk::label $w.content.gemini.keylbl -text "API Key:"
    pack $w.content.gemini.keylbl -anchor w
    ttk::entry $w.content.gemini.key -width 50 -textvariable ::auto_comment::apiKey
    pack $w.content.gemini.key -fill x -pady {0 5}

    ttk::label $w.content.gemini.modellbl -text "Model:"
    pack $w.content.gemini.modellbl -anchor w
    ttk::combobox $w.content.gemini.model -width 30 -textvariable ::auto_comment::model \
        -values [::auto_comment::modelChoices gemini]
    pack $w.content.gemini.model -anchor w -pady {0 5}

    ttk::button $w.content.gemini.load -text "Load Models" \
        -command [list ::auto_comment::loadModels $w.content.gemini.model gemini]
    pack $w.content.gemini.load -anchor w -pady {0 5}

    ttk::button $w.content.gemini.open -text "Get Gemini Key" -command {
        openURL "https://aistudio.google.com/apikey"
    }
    pack $w.content.gemini.open -anchor w

    # --- DeepSeek section ---
    ttk::labelframe $w.content.deepseek -text "DeepSeek" -padding 10
    pack $w.content.deepseek -fill x -pady {0 10}

    ttk::label $w.content.deepseek.keylbl -text "API Key:"
    pack $w.content.deepseek.keylbl -anchor w
    ttk::entry $w.content.deepseek.key -width 50 -textvariable ::auto_comment::deepseekApiKey
    pack $w.content.deepseek.key -fill x -pady {0 5}

    ttk::label $w.content.deepseek.modellbl -text "Model:"
    pack $w.content.deepseek.modellbl -anchor w
    ttk::combobox $w.content.deepseek.model -width 30 -textvariable ::auto_comment::deepseekModel \
        -values [::auto_comment::modelChoices deepseek]
    pack $w.content.deepseek.model -anchor w -pady {0 5}

    ttk::button $w.content.deepseek.load -text "Load Models" \
        -command [list ::auto_comment::loadModels $w.content.deepseek.model deepseek]
    pack $w.content.deepseek.load -anchor w -pady {0 5}

    ttk::button $w.content.deepseek.open -text "Get DeepSeek Key" -command {
        openURL "https://platform.deepseek.com/api_keys"
    }
    pack $w.content.deepseek.open -anchor w

    # --- Buttons ---
    ttk::frame $w.buttons -padding {15 5}
    pack $w.buttons -fill x

    ttk::button $w.buttons.ok -text "OK" -command [list ::auto_comment::saveSettings $w]
    pack $w.buttons.ok -side right -padx 5

    bind $w <Return> [list ::auto_comment::saveSettings $w]
    bind $w <Escape> "destroy $w"

    ::auto_comment::syncProviderSections $w
    ::auto_comment::fitWindow $w
}

# ::auto_comment::saveSettings
#   Persist the provider settings and close the dialog.
#
#   These variables live in this namespace, and options.dat is loaded before
#   tcl/tools/auto_comment.tcl exists, so a file holding only
#   "set ::auto_comment::provider ..." would fail to load ("parent namespace
#   doesn't exist") at the next start. options.write is the whole-file saver
#   behind Options > Save Options: it writes "namespace eval" for every
#   registered namespace first, so the namespace exists by the time the value
#   is set. Using it here is also why the dialog no longer asks the user to
#   remember a separate menu action: a key typed and then lost on exit is the
#   one failure that looks like the feature is broken.
proc ::auto_comment::saveSettings {w} {
    if {[catch {options.write} err]} {
        tk_messageBox -icon warning -type ok -title "Auto Comment" \
            -message "Could not save the settings to the options file:\n\n$err" \
            -parent $w
    }
    destroy $w
}

# ::auto_comment::fetchLichessEval
#   Fetches cloud evaluation from the Lichess API.
#   Returns the raw JSON string, or "" on failure.
#
proc ::auto_comment::fetchLichessEval {fen {variant "standard"}} {
    set urlFen [string map {" " "%20"} $fen]
    set url "$::auto_comment::lichessApiUrl?fen=$urlFen&multiPv=5&variant=$variant"

    set result ""
    if {![catch {exec curl -s --max-time 10 -H "Accept: */*" $url} result]} {
        # Check that it contains PV data (not an error response)
        if {[regexp {"pvs"} $result]} {
            return $result
        }
    }
    return ""
}

# ::auto_comment::fetchChessDBEval
#   Fallback: fetches evaluation from chessdb.cn.
#   Returns the raw JSON/text string, or "" on failure.
#
proc ::auto_comment::fetchChessDBEval {fen} {
    set urlFen [string map {" " "%20" "/" "%2F"} $fen]
    set url "$::auto_comment::chessdbApiUrl?action=queryall&board=$urlFen&showall=0&json=1"

    set result ""
    if {![catch {exec curl -s --max-time 10 $url} result]} {
        if {[string length $result] > 5} {
            return $result
        }
    }
    return ""
}
# ::auto_comment::formatLichessEval
#   Converts raw Lichess cloud eval JSON into human-readable text
#   with SAN notation and formatted scores.
#
proc ::auto_comment::formatLichessEval {jsonData fen} {
    # Determine side to move
    set color [lindex [split $fen] 1]
    set sideToMove [expr {$color eq "w" ? "White" : "Black"}]

    # Extract depth
    set depth ""
    regexp {"depth":(\d+)} $jsonData -> depth

    set isBlack [expr {$color eq "b"}]
    set result "Position evaluation (depth $depth). $sideToMove to move.\n"
    append result "Lines are ranked from best to worst for $sideToMove. Line 1 is the engine's top recommendation.\n"
    append result "Each line has a quality label showing how it compares to the best move.\n"

    # Move-label mapping: first SAN move -> quality label
    set moveLabels [dict create]

    # First pass: collect all PVs with their scores
    set pvList {}
    if {[regexp -indices {"pvs"\s*:\s*\[} $jsonData match]} {
        set arrayStart [lindex $match 1]
        set remaining [string range $jsonData $arrayStart end]

        while {[regexp -indices {\{[^\}]+\}} $remaining objMatch]} {
            set objStart [lindex $objMatch 0]
            set objEnd [lindex $objMatch 1]
            set obj [string range $remaining $objStart $objEnd]

            set moves ""
            set cp ""
            set mate ""

            regexp {"moves"\s*:\s*"([^"]*)"} $obj -> moves
            regexp {"cp"\s*:\s*(-?\d+)} $obj -> cp
            regexp {"mate"\s*:\s*(-?\d+)} $obj -> mate

            if {$moves ne ""} {
                lappend pvList [list $moves $cp $mate]
            }

            set remaining [string range $remaining [expr {$objEnd + 1}] end]
        }
    }

    # Get the best score (first line) for comparison
    set bestCp 0
    if {[llength $pvList] > 0} {
        set firstCp [lindex [lindex $pvList 0] 1]
        if {$firstCp ne ""} {
            # Normalize to side-to-move perspective for comparison
            set bestCp [expr {$isBlack ? -1 * $firstCp : $firstCp}]
        }
    }

    # No PVs found — return empty
    if {[llength $pvList] == 0} {
        return [list "" [dict create]]
    }

    # Second pass: format with quality labels
    set lineNum 1
    foreach pv $pvList {
        lassign $pv moves cp mate

        # Compute quality label based on centipawn loss from best
        set label "best"
        if {$lineNum > 1 && $cp ne ""} {
            set thisCp [expr {$isBlack ? -1 * $cp : $cp}]
            set cpLoss [expr {$bestCp - $thisCp}]
            if {$cpLoss < 10} {
                set label "equal"
            } elseif {$cpLoss < 50} {
                set label "slightly worse"
            } elseif {$cpLoss < 100} {
                set label "inaccuracy"
            } elseif {$cpLoss < 200} {
                set label "mistake"
            } else {
                set label "blunder"
            }
        } elseif {$lineNum == 1 && $mate ne ""} {
            set label "best (mate)"
        }

        # Convert UCI to SAN
        set sanMoves [::lichess_eval::uciToSan $moves $fen]
        set numberedMoves [::lichess_eval::formatLine $fen $sanMoves]

        # Extract the first SAN move for move-label mapping
        set firstMove [lindex [split $sanMoves] 0]
        if {$firstMove ne ""} {
            dict set moveLabels $firstMove $label
        }

        append result "Line $lineNum ($label): $numberedMoves\n"
        incr lineNum
    }

    return [list $result $moveLabels]
}

# ::auto_comment::formatChessDBEval
#   Converts raw ChessDB JSON into human-readable text.
#   ChessDB already provides SAN notation, scores, and winrates.
#
proc ::auto_comment::formatChessDBEval {jsonData fen} {
    set color [lindex [split $fen] 1]
    set sideToMove [expr {$color eq "w" ? "White" : "Black"}]

    set result "Position evaluation (chessdb.cn). $sideToMove to move.\n"
    append result "Moves are ranked from best to worst for $sideToMove. Move 1 is the engine's top recommendation.\n"
    append result "Each move has a quality label showing how it compares to the best move.\n"
    append result "Top moves:\n"

    # Move-label mapping: SAN move -> quality label
    set moveLabels [dict create]

    # Parse individual move objects from the JSON "moves" array
    # to avoid cross-object mismatches when some scores are "??"
    set moveList {}
    if {[regexp -indices {"moves"\s*:\s*\[} $jsonData arrayMatch]} {
        set arrayStart [lindex $arrayMatch 1]
        set remaining [string range $jsonData $arrayStart end]

        while {[llength $moveList] < 5 && \
               [regexp -indices {\{[^\}]+\}} $remaining objMatch]} {
            set objStart [lindex $objMatch 0]
            set objEnd [lindex $objMatch 1]
            set obj [string range $remaining $objStart $objEnd]

            set san ""
            set score ""
            set winrate ""
            regexp {"san"\s*:\s*"([^"]*)"} $obj -> san
            regexp {"score"\s*:\s*(-?\d+)} $obj -> score
            regexp {"winrate"\s*:\s*"([^"]*)"} $obj -> winrate

            # Only include moves with a known numeric score
            if {$san ne "" && $score ne ""} {
                lappend moveList [list $san $score $winrate]
            }

            set remaining [string range $remaining [expr {$objEnd + 1}] end]
        }
    }

    # No moves found — return empty
    if {[llength $moveList] == 0} {
        return [list "" [dict create]]
    }

    # Get best score for comparison (chessdb scores are from side-to-move perspective)
    set bestScore [lindex [lindex $moveList 0] 1]

    set count 0
    foreach mv $moveList {
        lassign $mv san score winrate
        incr count

        set label "best"
        if {$count > 1} {
            set cpLoss [expr {$bestScore - $score}]
            if {$cpLoss < 10} {
                set label "equal"
            } elseif {$cpLoss < 50} {
                set label "slightly worse"
            } elseif {$cpLoss < 100} {
                set label "inaccuracy"
            } elseif {$cpLoss < 200} {
                set label "mistake"
            } else {
                set label "blunder"
            }
        }

        dict set moveLabels $san $label
        append result "$count. $san ($label)\n"
    }

    return [list $result $moveLabels]
}

proc ::auto_comment::buildPrompt {fen evalText movePlayed variant {opening ""} {nagSymbol ""} {includeSymbols 1} {whitePerspective 0} {whoMoved ""} {isSingleMove 0} {pgn ""} {treeInfo ""}} {
    if {$whoMoved eq ""} { set whoMoved "the player who just moved" }

    set prompt "You are a chess commentator writing a short, plain-language annotation for club-level players. You are given objective engine analysis. TRUST it completely: use the quality labels and the VERDICT exactly as provided, and add only a clear explanation of WHY.

Write your commentary about the move just played by $whoMoved.

===== HOW TO READ THE ENGINE ANALYSIS =====
- \"Line N\" is a candidate continuation (PV). Line 1 is ALWAYS the engine's best move; later lines are progressively worse alternatives. Each line already carries a quality label (best, equal, slightly worse, inaccuracy, mistake, blunder).
- Move notation tells you WHO moved: \"13.\" is a White move, \"13...\" is a Black move. A candidate line beginning \"13...Re8\" is therefore a Black alternative. A move is good for Black when it LOWERS White's score, and good for White when it RAISES White's score.
- The played move's quality is stated in the VERDICT line. Repeat that label; do not recompute or second-guess it. The VERDICT already accounts for which side played the move.
- Numeric scores beside a line are from the SIDE TO MOVE's perspective (the evaluation block states who is to move): a positive score favors the side to move, a negative score favors the opponent. Scores labeled \"White's perspective\" (including all PGN/GROUND TRUTH and \"Engine score\" values) are from White's side regardless of who is to move: a positive value favors White and a negative value favors Black. A large value (e.g. -80.00 or +50.00) means a decisive or forced win, never equality.
- Scale reference: +/- 1.00 is roughly one pawn; +/- 10.00 is winning; mate is given as \"Mate in N\".

===== STRICT RULES =====
1. Ground every claim in the provided lines. Do NOT invent plans, motifs, tactics, or ideas that are not present in the PV sequences.
2. Never propose a move unless it appears in one of the provided lines, and never propose a move that was already played earlier in the game (check the PGN).
3. Castling: read castling rights from the FEN field (e.g. \"KQkq\", \"kq\", or \"-\"). Do not mention castling for a side whose right is absent.
4. For a blunder, mistake, or inaccuracy, name the better alternative from Line 1 and the concrete tactical or structural reason it is better.

===== OUTPUT FORMAT =====
- First line (exact form): \"VERDICT: $movePlayed is a {adjective} move according to the engine analysis.\" where {adjective} is the label in the VERDICT line. If the move delivers checkmate or forces a win, use \"best\". If the VERDICT line states that the move is absent from the engine's lines, use \"questionable\".
- Then write ONE concise paragraph:
  * blunder/mistake/inaccuracy: name the Line 1 alternative and why it is better. Under 70 words.
  * best/equal: explain the point of the move (threat, prevention, stabilization) using only the PV. Under 40 words.
  * checkmate: simply note that the move delivers checkmate and wins the game. Under 30 words.
- Use the tree statistics only to note whether the move is a common theoretical choice or a sideline.
- Plain text only: no markdown, no headings, no bold or italics."

    append prompt "\n\n===== GAME INFORMATION =====\n"
    if {$pgn ne ""} { append prompt "\nFull PGN:\n$pgn\n" }
    if {$opening ne ""} { append prompt "\nOpening: $opening" }
    append prompt "\n\nCurrent move: $movePlayed (by $whoMoved)"
    append prompt "\nFEN: $fen"
    if {$nagSymbol ne ""} { append prompt "\nAnnotation: $nagSymbol" }

    if {$treeInfo ne ""} {
        append prompt "\n\n===== TREE STATISTICS =====\n"
        append prompt $treeInfo
    }

    append prompt "\n\n===== ENGINE ANALYSIS =====\n"
    append prompt $evalText

    # For non-English UI languages, ask the LLM to answer in the user's language.
    # Keep engine analysis in standard SAN so move identities remain exact.
    if {$::language ne "E"} {
        if {[info exists ::langName($::language)]} {
            set langFullName $::langName($::language)
        } else {
            set langFullName $::language
        }

        append prompt "\n\n===== LANGUAGE =====\n"
        append prompt "\nCRITICAL: Write your ENTIRE response in $langFullName."

        if {$::translatePieces && [info exists ::transPieces($::language)]} {
            set pieceGuide {}
            set examplesFrom {}
            set examplesTo {}
            foreach {eng loc} $::transPieces($::language) {
                switch -- $eng {
                    K { lappend pieceGuide "King: $loc"; lappend examplesFrom "Ke2"; lappend examplesTo "${loc}e2" }
                    Q { lappend pieceGuide "Queen: $loc"; lappend examplesFrom "Qd1"; lappend examplesTo "${loc}d1" }
                    R { lappend pieceGuide "Rook: $loc"; lappend examplesFrom "Re1"; lappend examplesTo "${loc}e1" }
                    B { lappend pieceGuide "Bishop: $loc"; lappend examplesFrom "Bf4"; lappend examplesTo "${loc}f4" }
                    N { lappend pieceGuide "Knight: $loc"; lappend examplesFrom "Nc3"; lappend examplesTo "${loc}c3" }
                }
            }
            if {[llength $pieceGuide] > 0} {
                append prompt "\nYou MUST convert all chess piece letters to $langFullName notation in your response:"
                append prompt "\n  [join $pieceGuide {, }]"
                append prompt "\nExamples: [lindex $examplesFrom 0] becomes [lindex $examplesTo 0], [lindex $examplesFrom 4] becomes [lindex $examplesTo 4], [lindex $examplesFrom 3] becomes [lindex $examplesTo 3]."
                append prompt "\nPawn moves (e.g. e4, d5, c5) do NOT get a piece letter — leave them unchanged."
                append prompt "\nThe engine analysis above uses English letters (K, Q, R, B, N) — you MUST translate every piece letter when you mention a move in your commentary."
            }
        } else {
            append prompt "\nKeep standard English SAN piece letters (K, Q, R, B, N)."
        }
    }
    return $prompt
}

# ::auto_comment::cleanupText
#   Post-processes LLM output: strips markdown, fixes move notation.
#
proc ::auto_comment::cleanupText {text} {
    # Strip any markdown bold/italic markers the LLM might include
    set text [regsub -all {\*\*([^*]+)\*\*} $text {\1}]
    set text [regsub -all {\*([^*]+)\*} $text {\1}]
    # Fix capitalized pawn moves: A6->a6, C5->c5, etc.
    # One pass per file letter avoids unsafe subst with command substitution.
    foreach cap {A B C D E F G H} {
        set low [string tolower $cap]
        set text [regsub -all "(\[^a-zA-Z\])${cap}(\[1-8\])" $text "\\1${low}\\2"]
    }
    # Determine piece-letter set for case normalization.
    # English defaults to bknqr. For translated-piece languages, derive from transPieces.
    set pieceLetters "bknqr"
    if {$::language ne "E" && $::translatePieces && [info exists ::transPieces($::language)]} {
        set pieceLetters ""
        foreach {eng loc} $::transPieces($::language) {
            if {$eng in {K Q R B N}} {
                set lower [string tolower $loc]
                if {[string length $lower] == 1 && [string is ascii -strict $lower] && [string is alpha -strict $lower]} {
                    append pieceLetters $lower
                }
            }
        }
        if {$pieceLetters eq ""} {
            set pieceLetters "bknqr"
        }
    }

    # Fix lowercase piece moves (nf3->Nf3) and captures (nxf3->Nxf3).
    # One pass per piece letter avoids unsafe subst with command substitution.
    foreach letter [split $pieceLetters ""] {
        set upper [string toupper $letter]
        # Non-letter context before the piece letter
        set text [regsub -all "(\[^a-zA-Z\])${letter}(\[a-h\]\[1-8\])" $text "\\1${upper}\\2"]
        set text [regsub -all "(\[^a-zA-Z\])${letter}(x\[a-h\]\[1-8\])" $text "\\1${upper}\\2"]
        # Start-of-string context
        set text [regsub "^${letter}(\[a-h\]\[1-8\])" $text "${upper}\\1"]
        set text [regsub "^${letter}(x\[a-h\]\[1-8\])" $text "${upper}\\1"]
    }

    # Safety net: convert any remaining English piece letters in move patterns
    # to local notation. This catches cases where the LLM echoes English SAN
    # despite being told to use local notation.
    if {$::language ne "E" && $::translatePieces && [info exists ::transPieces($::language)]} {
        foreach {eng loc} $::transPieces($::language) {
            if {$eng in {K Q R B N} && $eng ne $loc} {
                # Match: PieceLetter + optional disambiguation (file or rank)
                #        + optional 'x' + file + rank
                # E.g.: Nc3, Nxc3, Nbc3, N1c3, Nbxc3
                set pat "(^|\[^a-zA-Z\])${eng}(\[a-h1-8\]?x?\[a-h\]\[1-8\])"
                set text [regsub -all $pat $text "\\1${loc}\\2"]
            }
        }
    }

    return [string trim $text]
}

# ::auto_comment::escapeJson
#   Escapes a string for embedding inside a JSON string value.
#
proc ::auto_comment::escapeJson {str} {
    return [string map {
        "\\" "\\\\"
        "\"" "\\\""
        "\n" "\\n"
        "\r" "\\r"
        "\t" "\\t"
    } $str]
}

# ::auto_comment::fetchGeminiModels
#   Queries the Gemini API for the current list of available models.
#   Returns a list of model names (without the "models/" prefix), or {} on failure.
#
proc ::auto_comment::fetchGeminiModels {} {
    set url "$::auto_comment::geminiApiBase?pageSize=200"
    set result ""
    if {[catch {exec curl -s --max-time 15 \
            -H "x-goog-api-key: $::auto_comment::apiKey" \
            $url 2>@1} result]} {
        ::auto_comment::logDebug "Auto Comment: fetchGeminiModels curl error: $result"
        return {}
    }

    set models {}
    foreach {- name} [regexp -all -inline {"name"\s*:\s*"models/([^"]+)"} $result] {
        # Only the text-generation models are relevant for generateContent.
        if {[string match "*gemini*" $name]} {
            lappend models $name
        }
    }
    return [lsort -dictionary $models]
}

# ::auto_comment::fetchDeepSeekModels
#   Queries the DeepSeek API for the current list of available models.
#   Returns a list of model ids, or {} on failure.
#
proc ::auto_comment::fetchDeepSeekModels {} {
    set url "$::auto_comment::deepseekApiBase/models"
    set result ""
    set headers {}
    if {[::auto_comment::cleartextKeyError $url $::auto_comment::deepseekApiKey] eq ""} {
        lappend headers -H "Authorization: Bearer $::auto_comment::deepseekApiKey"
    } else {
        ::auto_comment::logDebug "Auto Comment: not sending the API key to $url: not https"
    }
    if {[catch {exec curl -s --max-time 15 {*}$headers \
            $url 2>@1} result]} {
        ::auto_comment::logDebug "Auto Comment: fetchDeepSeekModels curl error: $result"
        return {}
    }

    set models {}
    foreach {- id} [regexp -all -inline {"id"\s*:\s*"([^"]+)"} $result] {
        lappend models $id
    }
    return [lsort -dictionary $models]
}

# ::auto_comment::loadModels
#   Populates a model combobox with the current models from the given provider.
#   Warns the user if the fetch fails (e.g. missing API key or no network).
#
# ::auto_comment::fetchUrlModels
#   Ask an endpoint what models it has. /v1/models first (OpenAI-compatible),
#   then Ollama's /api/tags for a server that only speaks the native API. Model
#   lists include embedding models, so the caller must let the user choose.
proc ::auto_comment::fetchUrlModels {base key {modelsUrl ""}} {
    set base [::auto_comment::baseUrl $base]
    if {$base eq "" && $modelsUrl eq ""} { return {} }
    # An explicit URL wins: a gateway's model list is not always a child of its
    # chat root (OpenCode serves .../inference/v1/models, while chat lives under
    # .../inference/openai/v1/...).
    set tries {}
    if {$modelsUrl ne ""} {
        lappend tries [list $modelsUrl {"id"\s*:\s*"([^"]+)"}]
    } else {
        lappend tries [list [::auto_comment::modelsUrl $base] {"id"\s*:\s*"([^"]+)"}] \
                      [list "$base/api/tags" {"name"\s*:\s*"([^"]+)"}]
    }
    set ids {}
    foreach {target re} $tries {
        set cmd [list curl -s --max-time 10 -H {Accept: application/json}]
        if {$key ne ""} {
            # the key only rides an https (or loopback) connection
            if {[::auto_comment::cleartextKeyError $target $key] eq ""} {
                lappend cmd -H "Authorization: Bearer $key"
            } else {
                ::auto_comment::logDebug "Auto Comment: not sending the API key to $target: not https"
            }
        }
        lappend cmd $target
        set raw ""
        if {[catch {exec {*}$cmd 2>@1} raw]} { continue }
        foreach {all id} [regexp -all -inline $re $raw] { lappend ids $id }
        if {[llength $ids]} { break }
    }
    return [lsort -unique $ids]
}

# ::auto_comment::chatCompletionsOnly
#   Drop the models an OpenAI-compatible gateway serves through another API
#   family, because /chat/completions cannot reach them: GPT and Grok are
#   Responses, Claude and most Qwen are Messages, Jev is SystemOne. The live
#   model list does not say which family a model is on, so this keys on the
#   documented table (opencode.ai/v2/docs/console/models). It fails open: an
#   unknown new model stays in the list.
#
#   The free tier is dropped as well: those models answer OpenCode itself and
#   return 403 to any other client, key or no key.
proc ::auto_comment::chatCompletionsOnly {ids} {
    set out {}
    foreach id $ids {
        if {$id in {test big-pickle}} { continue }
        if {[string match "*-free" $id]} { continue }
        if {[regexp {^(gpt-|claude-|gemini-|grok-|muse-|jev-)} $id]} { continue }
        if {[string match "qwen*" $id] && $id ne "qwen3.8-max"} { continue }
        lappend out $id
    }
    return $out
}

proc ::auto_comment::loadModels {combo provider} {
    switch -- $provider {
        deepseek {
            set label "DeepSeek"
            set models [::auto_comment::fetchDeepSeekModels]
        }
        local {
            set label "the local server"
            set models [::auto_comment::fetchUrlModels $::auto_comment::localUrl ""]
        }
        openai {
            set label "the endpoint"
            set models [::auto_comment::fetchUrlModels $::auto_comment::openaiUrl $::auto_comment::openaiKey]
        }
        opencode {
            set label "OpenCode Console"
            set models [::auto_comment::chatCompletionsOnly \
                [::auto_comment::fetchUrlModels "" $::auto_comment::opencodeKey \
                    $::auto_comment::opencodeModelsUrl]]
        }
        default {
            set label "Gemini"
            set models [::auto_comment::fetchGeminiModels]
        }
    }
    if {[llength $models] > 0} {
        $combo configure -values $models
        # an empty model field is why a review would say "no model selected":
        # take the first one the endpoint offers so that cannot happen silently
        if {[$combo cget -textvariable] ne ""} {
            set var [$combo cget -textvariable]
            if {![info exists $var] || [set $var] eq ""} {
                set $var [lindex $models 0]
            }
        }
    } else {
        tk_messageBox -icon warning -type ok -title "Auto Comment" \
            -message "Could not retrieve a model list from $label.\n\nCheck the endpoint, the API key and the internet connection." \
            -parent .
    }
}

# ::auto_comment::queryGemini
#   Sends the prompt to the Gemini API.
#   Returns the generated commentary text, or "" on failure.
#
proc ::auto_comment::queryGemini {prompt} {
    set model $::auto_comment::model
    set url "$::auto_comment::geminiApiBase/$model:generateContent"

    # DEBUG: Log the prompt being sent
    ::auto_comment::logDebug "\n===== GEMINI API REQUEST ====="
    ::auto_comment::logDebug "Model: $model"
    ::auto_comment::logDebug "Prompt:"
    ::auto_comment::logDebug $prompt
    ::auto_comment::logDebug "===============================\n"

    set escaped [::auto_comment::escapeJson $prompt]
    set jsonBody "{\"contents\":\[{\"parts\":\[{\"text\":\"$escaped\"}\]}\]}"

    set tmpfile [::auto_comment::writeRequestFile $jsonBody req]

    set result ""
    set ok 0

    if {![catch {exec curl -s --connect-timeout 15 --max-time 60 \
            -H "Content-Type: application/json" \
            -H "x-goog-api-key: $::auto_comment::apiKey" \
            -X POST \
            -d @$tmpfile \
            $url 2>@1} result]} {
        set ok 1
    } else {
        ::auto_comment::logDebug "Auto Comment: curl error: $result"
    }

    catch {file delete -force $tmpfile}

    if {!$ok} {
        return "ERROR: Gemini request failed (network error or timeout): [string range [string trim $result] 0 300]"
    }

    # DEBUG: Log the raw response
    ::auto_comment::logDebug "\n===== GEMINI API RESPONSE ====="
    ::auto_comment::logDebug $result
    ::auto_comment::logDebug "===============================\n"

    # Check for API error responses
    if {[regexp {"error"\s*:\s*\{} $result]} {
        set errMsg ""
        regexp {"message"\s*:\s*"([^"]*)"} $result -> errMsg
        ::auto_comment::logDebug "Auto Comment: Gemini API error: $errMsg"
        ::auto_comment::logDebug "Auto Comment: Full response: $result"
        return "ERROR: $errMsg"
    }

    # Extract text from Gemini response
    set text ""
    if {[regexp {"text"\s*:\s*"((?:[^"\\]|\\.)*)"} $result -> rawText]} {
        set text [string map {
            "\\n" "\n"
            "\\r" ""
            "\\t" " "
            "\\\"" "\""
            "\\\\" "\\"
        } $rawText]
    } else {
        ::auto_comment::logDebug "Auto Comment: Could not parse Gemini response: $result"
        return "ERROR: Could not parse the Gemini response (it may have been blocked by safety filters)."
    }

    # DEBUG: Log the extracted commentary before cleanup
    ::auto_comment::logDebug "\n===== GEMINI EXTRACTED COMMENTARY (before cleanup) ====="
    ::auto_comment::logDebug $text
    ::auto_comment::logDebug "========================================================\n"

    set text [::auto_comment::cleanupText $text]
    if {$text eq ""} {
        return "ERROR: Gemini returned an empty response (it may have been blocked by safety filters)."
    }
    return $text
}

# ::auto_comment::queryDeepSeek
#   Sends the prompt to the DeepSeek API (OpenAI-compatible).
#   Returns the generated commentary text, or "" on failure.
#
proc ::auto_comment::queryDeepSeek {prompt} {
    set model $::auto_comment::deepseekModel
    set url "$::auto_comment::deepseekApiBase/chat/completions"

    # DEBUG: Log the prompt being sent
    ::auto_comment::logDebug "\n===== DEEPSEEK API REQUEST ====="
    ::auto_comment::logDebug "Model: $model"
    ::auto_comment::logDebug "Prompt:"
    ::auto_comment::logDebug $prompt
    ::auto_comment::logDebug "================================\n"

    set escapedPrompt [::auto_comment::escapeJson $prompt]
    set jsonBody "{\"model\":\"$model\",\"messages\":\[{\"role\":\"user\",\"content\":\"$escapedPrompt\"}\],\"stream\":false,\"temperature\":1.0}"

    set tmpfile [::auto_comment::writeRequestFile $jsonBody req]

    set result ""
    set ok 0

    if {![catch {exec curl -s --connect-timeout 15 --max-time 180 \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $::auto_comment::deepseekApiKey" \
            -X POST \
            -d @$tmpfile \
            $url 2>@1} result]} {
        set ok 1
    } else {
        ::auto_comment::logDebug "Auto Comment: curl error: $result"
    }

    catch {file delete -force $tmpfile}

    if {!$ok} {
        return "ERROR: DeepSeek request failed (network error or timeout): [string range [string trim $result] 0 300]"
    }

    # DEBUG: Log the raw response
    ::auto_comment::logDebug "\n===== DEEPSEEK API RESPONSE ====="
    ::auto_comment::logDebug $result
    ::auto_comment::logDebug "=================================\n"

    # Check for API error responses
    if {[regexp {"error"\s*:\s*\{} $result]} {
        set errMsg ""
        regexp {"message"\s*:\s*"([^"]*)"} $result -> errMsg
        ::auto_comment::logDebug "Auto Comment: DeepSeek API error: $errMsg"
        ::auto_comment::logDebug "Auto Comment: Full response: $result"
        return "ERROR: $errMsg"
    }

    # Extract text from DeepSeek response (OpenAI format)
    # {"choices":[{"message":{"content":"..."},...}],...}
    set text ""
    if {[regexp {"content"\s*:\s*"((?:[^"\\]|\\.)*)"} $result -> rawText]} {
        set text [string map {
            "\\n" "\n"
            "\\r" ""
            "\\t" " "
            "\\\"" "\""
            "\\\\" "\\"
        } $rawText]
    } else {
        ::auto_comment::logDebug "Auto Comment: Could not parse DeepSeek response: $result"
        return "ERROR: Could not parse the DeepSeek response."
    }

    # DEBUG: Log the extracted commentary before cleanup
    ::auto_comment::logDebug "\n===== DEEPSEEK EXTRACTED COMMENTARY (before cleanup) ====="
    ::auto_comment::logDebug $text
    ::auto_comment::logDebug "==========================================================\n"

    set text [::auto_comment::cleanupText $text]
    if {$text eq ""} {
        return "ERROR: DeepSeek returned an empty response (the model may have hit its output limit before writing any commentary)."
    }
    return $text
}

# ::auto_comment::getOpeningName
#   Retrieves the full opening name for a given ECO code.
#
proc ::auto_comment::getOpeningName {eco} {
    if {$eco eq ""} { return "" }
    
    # sc_eco summary $eco 0 returns lines from scid.eco:
    # "A00 [Barnes Opening]  1. f3"
    # Note: the second argument 0 disables translation for consistent parsing.
    set summary [sc_eco summary $eco 0]
    if {$summary ne ""} {
        set lines [split $summary "\n"]
        foreach line $lines {
            if {[regexp {^([A-E]\d\d[a-z]?\d?)\s+\[([^\]]+)\]} $line -> code description]} {
                # Return the matched code and description
                # return "$code $description"
                return "$description"
            }
        }
    }
    return $eco
}

# ::auto_comment::getTreeInfo
#   Fetches tree statistics for the current position and returns a formatted block.
proc ::auto_comment::getTreeInfo {baseId} {
    set treeBlock ""
    set currBase [sc_base current]

    # 1. Search the database for the current board position.
    # sc_filter search uses the current game position, which the caller has
    # already stepped back to before invoking getTreeInfo.
    if {$baseId != $currBase} {
        sc_base switch $baseId
    }
    
    catch {sc_filter search $baseId "tree" board}

    # 2. Fetch tree statistics using the combined filter '+dbfilter+tree'.
    set err [catch {sc_tree stats $baseId "+dbfilter+tree" 0 frequency 4} stats]
    
    # Restore original base if we switched
    if {$baseId != $currBase} {
        sc_base switch $currBase
    }
    
    if {$err} { return "" }
    
    set lines [split $stats "\n"]
    set count 0
    foreach line $lines {
        if {$count >= 3} break
        # Skip header, total lines and empty lines
        if {[string match "*Move(s)*" $line] || [string match "*TOTAL:*" $line] || [string trim $line] eq ""} continue

        # Parse the fixed-width output of sc_tree stats (tkscid.cpp)
        # Format emitted by tkscid.cpp (lines 8315-8286):
        # Base (0-49), Score (50-57), AvElo (58-63), Perf (64-69), AvLen (70-75),
        # AvYear (76-81), %Draws (82-87), %Win (88-99)
        # Example: " 1: e4 e5 Nf3 Nc6             A00      1234: 45.6%   52.3%  2100  2200    45  1995   32%      48.25%"
        # MoveSeq: 4-28, Games: 36-42, Success%: 51-57, %Draws: 82-87, %Win: 88-99
        catch {
            set moveSeq [string trim [string range $line 4 28]]
            if {$moveSeq eq "" || $moveSeq eq "---"} continue

            set games   [string trim [string range $line 36 42]]
            set success [string trim [string range $line 51 57]]
            set draws   [string trim [string range $line 82 87]]
            set win     [string trim [string range $line 88 99]]
            
            if {$treeBlock eq ""} {
                append treeBlock "Top 3 most frequent database lines for the current position (depth 4 plies):"
            }
            append treeBlock "\n- $moveSeq ($games games): Score $success, Draws $draws, Win $win"
            incr count
        }
    }
    return $treeBlock
}

# ::auto_comment::getTempDir
#   Returns a suitable temporary directory.
#
proc ::auto_comment::getTempDir {} {
    if {[info exists ::env(TMPDIR)]} {
        return $::env(TMPDIR)
    } elseif {[info exists ::env(TEMP)]} {
        return $::env(TEMP)
    } elseif {[info exists ::env(TMP)]} {
        return $::env(TMP)
    } elseif {[file isdirectory "/tmp"]} {
        return "/tmp"
    } else {
        return [pwd]
    }
}
