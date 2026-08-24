-- =====================================================================
--  UltiDash Toolbox: battery detail / editor (Flight Log companion)
--  The battery detail page (Edit / Delete), the edit/create form and the
--  models sub-page, in the Toolbox detail-page style. ONE form, TWO entry
--  flows (spec S1): the Flight Log viewer loads this module itself for
--  detail/edit/create, the host loads it for the battery query's "+ New"
--  (fltlog.load_batted). DISARMED-ONLY; arming or a fullscreen exit
--  closes every page and discards an open form -- ONLY Save writes, via
--  fltdata's line surgery, in the tool's own exclusive refresh cycle.
--  Cancel needs no control-level undo: the working copy (wgt.fb.e) is
--  simply dropped -- numberEdit commits into it on every keypress (its
--  keyboard RTN COMMITS; the control has no cancel path), so the pristine
--  state lives in fb.p / the untouched registry entry, never in a control.
--  Per-instance state on wgt.fb; M.close(wgt) frees it.
--  ONLY function-style string calls (method style crashes the widget state).
--
--  M.open(wgt, mode, ctx) -- mode "detail" (ctx.entry set) | "create".
--  ctx = { D = fltdata module, reg = loaded registry list, entry,
--          flights_for = function(id) -> logged-flight count (optional),
--          known_models = { as-typed names }, craft = connected craft,
--          preset_models = { names } (battpick "+ New" presets the craft),
--          on_change = function(wgt, what, id) -> fresh entry (after a
--              successful write; the caller reloads its registry),
--          on_close = function(wgt) (leave the module entirely) }
-- =====================================================================

local M = {}

-- shared palettes live in toolbox/common.lua, handed in by the loader (host
-- or viewer) via M.init; nil-guarded for a partial deploy
local C = nil
function M.init(common) C = common end

local function palette(wgt)
    local opt = wgt.options or {}
    if C ~= nil and (opt.TbSun == 1 or opt.TbSun == true) then return C.sun_palette() end
    if wgt.tb_pal then return wgt.tb_pal end
    if C ~= nil then return C.fallback_palette() end
    -- last resort (common.lua missing): the dark fallback literals
    return { bg = lcd.RGB(0, 0, 0), accent = lcd.RGB(0, 229, 255),
             hint = lcd.RGB(255, 122, 26), line = lcd.RGB(56, 60, 64),
             text = lcd.RGB(240, 240, 240), textDim = lcd.RGB(150, 156, 162),
             bannerBg = lcd.RGB(255, 68, 56), bannerFg = lcd.RGB(0, 0, 0) }
end

local function trim(s) return string.match(tostring(s or ""), "^%s*(.-)%s*$") end

-- ---------------------------------------------------------------------
-- field sanitisers (spec 6.1/6.2) -- module functions so they can be
-- proven without an LVGL runtime
-- ---------------------------------------------------------------------

-- id charset [A-Za-z0-9_-]; everything else stripped on set
function M.sanitize_id(s)
    return string.sub(string.gsub(tostring(s or ""), "[^A-Za-z0-9_%-]", ""), 1, 24)
end

-- name: ';' (field separator) and control characters stripped, trimmed, cap 24
function M.sanitize_name(s)
    s = string.gsub(tostring(s or ""), "[;%c]", "")
    return string.sub(trim(s), 1, 24)
end

-- free-text model name: commas are the models LIST separator -> stripped (the
-- same reason append_flight flattens them out of ids); ';' would end the field
function M.sanitize_model(s)
    s = string.gsub(tostring(s or ""), "[,;%c]", "")
    return string.sub(trim(s), 1, 32)
end

-- smallest free positive integer id (B9) -- matches the hand-numbered style
function M.free_id(reg)
    local used = {}
    for i = 1, #(reg or {}) do used[trim(reg[i].id)] = true end
    local n = 1
    while used[tostring(n)] do n = n + 1 end
    return tostring(n)
end

-- ---------------------------------------------------------------------
-- state
-- ---------------------------------------------------------------------

local function copy_entry(e)
    local t = { id = e.id, name = e.name, cap = e.cap, cycles = e.cycles,
                profile = e.profile, models_all = e.models_all, models = {} }
    for i = 1, #e.models do t.models[i] = e.models[i] end
    return t
end

function M.open(wgt, mode, ctx)
    local fb = { ctx = ctx or {}, hit = {} }
    wgt.fb = fb
    if mode == "create" then
        fb.mode = "create"
        fb.view = "form"
        local preset = fb.ctx.preset_models
        local models = {}
        if type(preset) == "table" then
            for i = 1, #preset do
                local m = trim(preset[i])
                if m ~= "" then models[#models + 1] = m end
            end
        end
        fb.e = { id = M.free_id(fb.ctx.reg), name = "", cap = 0, cycles = 0,
                 profile = 0, models_all = (#models == 0), models = models }
        fb.p = copy_entry(fb.e)
        fb.models_touched = false
    else
        fb.mode = "edit"
        fb.view = "detail"
        fb.cur = fb.ctx.entry
    end
    wgt.fb_dirty = true
end

function M.close(wgt)
    wgt.fb = nil
end

-- forced-exit cleanup (close_tool_page): nothing held open beyond the state
M.cleanup = M.close

-- leave the module entirely (detail back / create cancel)
local function leave(wgt, fb)
    local cb = fb.ctx.on_close
    M.close(wgt)
    if cb ~= nil then pcall(cb, wgt) end
end

local function flights_of(fb, id)
    local f = fb.ctx.flights_for
    if f == nil then return 0 end
    local ok, n = pcall(f, id)
    return (ok and type(n) == "number") and n or 0
end

local function disp_name(b)
    if b == nil then return "?" end
    return (b.name ~= nil and b.name ~= "") and b.name or (b.id or "?")
end

-- working copy from the registry entry; '*' anywhere in the parsed models
-- list means "all" (parser contract), the other names are kept so untoggling
-- All models starts from them
local function start_edit(wgt, fb)
    local cur = fb.cur
    local models, all = {}, true
    local mm = cur.models
    if mm ~= nil and #mm > 0 then
        all = false
        for i = 1, #mm do
            if mm[i] == "*" then all = true else models[#models + 1] = mm[i] end
        end
    end
    fb.e = { id = cur.id, name = cur.name or "", cap = cur.cap or 0,
             cycles = cur.cycles or 0, profile = cur.profile or 0,
             models_all = all, models = models }
    fb.p = copy_entry(fb.e)
    fb.models_touched = false
    fb.err = nil
    fb.view = "form"
    wgt.fb_dirty = true
end

-- Cancel discards: only Save ever writes, and the working copy dies here.
-- The detail page re-renders from the UNTOUCHED registry entry (fb.cur) --
-- that is the "own pristine copy" the numberEdit correction demands.
local function cancel_form(wgt, fb)
    if fb.mode == "edit" then
        fb.e, fb.p, fb.err = nil, nil, nil
        fb.view = "detail"
        wgt.fb_dirty = true
    else
        leave(wgt, fb)
    end
end

-- ---------------------------------------------------------------------
-- save / delete (executed in M.refresh's own exclusive cycle, never in
-- the tap that requested them -- the Toolbox io rule)
-- ---------------------------------------------------------------------

local function models_string(e)
    if e.models_all or #e.models == 0 then return nil end
    return table.concat(e.models, ",")
end

local function handle_result(wgt, fb, res, what, id)
    if res == true then
        fb.err = nil
        local fresh = nil
        if fb.ctx.on_change ~= nil then
            local okc, r = pcall(fb.ctx.on_change, wgt, what, id)
            if okc then fresh = r end
        end
        if what == "updated" then
            if fresh ~= nil then fb.cur = fresh end
            fb.e, fb.p = nil, nil
            fb.view = "detail"
            wgt.fb_dirty = true
        else            -- "created" / "deleted": back to the caller
            leave(wgt, fb)
        end
        return
    end
    if res == "toobig" then
        fb.err = "batteries.cfg too large to edit on the radio"
    elseif res == "collision" then
        -- the FILE-level recheck (the loaded list said free, the file changed)
        fb.dlg = { title = "Not possible", only_ok = true,
                   msg = "id '" .. tostring(id) .. "' is already in use" }
    elseif res == "notfound" then
        fb.err = "Pack not found - registry changed, reopen the list"
        if fb.ctx.on_change ~= nil then pcall(fb.ctx.on_change, wgt, "reload", nil) end
    else
        fb.err = "Save failed - card full or write-protected?"
    end
    wgt.fb_dirty = true
end

local function do_save(wgt, fb)
    local D = fb.ctx.D
    if D == nil then return handle_result(wgt, fb, false) end
    local id = trim(fb.e.id)
    local okc, res
    if fb.mode == "create" then
        okc, res = pcall(D.create_battery, {
            id = id, name = fb.e.name,
            cap = fb.e.cap > 0 and fb.e.cap or nil,
            models = models_string(fb.e),
            profile = fb.e.profile >= 1 and fb.e.profile or nil,
            cycles = fb.e.cycles })
        handle_result(wgt, fb, okc and res or false, "created", id)
        return
    end
    -- edit: pass ONLY the touched fields -- an untouched field keeps its exact
    -- bytes in the file (fltdata edit_line's keep-verbatim contract, spec S4)
    local a, any = {}, false
    if id ~= fb.p.id then a.id = id; any = true end
    if fb.e.name ~= fb.p.name then a.name = fb.e.name; any = true end
    if fb.e.cap ~= fb.p.cap then
        a.cap = fb.e.cap > 0 and fb.e.cap or false; any = true      -- 0 = unset -> key removed
    end
    if fb.e.cycles ~= fb.p.cycles then a.cycles = fb.e.cycles; any = true end
    if fb.e.profile ~= fb.p.profile then
        a.profile = fb.e.profile >= 1 and fb.e.profile or false; any = true
    end
    if fb.models_touched then
        local ms = models_string(fb.e)
        a.models = ms ~= nil and ms or false                        -- all -> key removed
        any = true
    end
    if not any then         -- nothing changed: no write, straight back
        fb.e, fb.p = nil, nil
        fb.view = "detail"
        wgt.fb_dirty = true
        return
    end
    okc, res = pcall(D.update_battery, fb.p.id, a)
    handle_result(wgt, fb, okc and res or false, "updated", id)
end

local function do_delete(wgt, fb)
    local D = fb.ctx.D
    if D == nil or fb.cur == nil then return handle_result(wgt, fb, false) end
    local okc, res = pcall(D.delete_battery, fb.cur.id)
    handle_result(wgt, fb, okc and res or false, "deleted", fb.cur.id)
end

-- Save button: validation (spec 6.1), then the deferred write request.
-- Uniqueness runs against the LOADED registry here (named message); the write
-- layer rechecks against the file, which may have changed since.
local function on_save(wgt, fb)
    local id = trim(fb.e.id)
    if id == "" then
        fb.dlg = { title = "Not possible", msg = "id must not be empty", only_ok = true }
        wgt.fb_dirty = true
        return
    end
    local reg = fb.ctx.reg or {}
    local old = (fb.mode == "edit") and fb.p.id or nil
    for i = 1, #reg do
        if reg[i].id == id and id ~= old then
            fb.dlg = { title = "Not possible", only_ok = true,
                       msg = "id '" .. id .. "' already belongs to " .. disp_name(reg[i]) }
            wgt.fb_dirty = true
            return
        end
    end
    if old ~= nil and id ~= old then
        -- B7: warn instead of migrating; flights.csv is never rewritten
        local n = flights_of(fb, old)
        if n > 0 then
            fb.dlg = { title = "Rename id?", ok_txt = "Rename",
                msg = n .. " logged flight" .. (n == 1 and "" or "s") .. " reference '"
                    .. old .. "' and will lose the link. Rename anyway?",
                on_ok = function(w, fbx) fbx.dlg = nil; fbx.save_req = true; w.fb_dirty = true end }
            wgt.fb_dirty = true
            return
        end
    end
    fb.save_req = true
end

-- ---------------------------------------------------------------------
-- UI helpers (adjed/logview conventions: plain rects + own hit testing --
-- a focusable type="button" would capture PAGE/RTN)
-- ---------------------------------------------------------------------

local function add_hit(fb, x, y, w, h, fn, cool)
    fb.hit[#fb.hit + 1] = { x = x, y = y, w = w, h = h, fn = fn, cool = cool }
end

local function button(fb, layout, P, x, y, w, h, txt, font, fn)
    layout[#layout + 1] = { type = "rectangle", x = x, y = y, w = w, h = h,
        thickness = 1, rounded = 4, color = P.line }
    local _, th = lcd.sizeText(txt, font)
    layout[#layout + 1] = { type = "label", x = x, y = y + (h - th) / 2,
        w = w, h = th, font = font, align = CENTER, color = P.text, text = txt }
    add_hit(fb, x, y, w, h, fn, 30)
end

-- clip free text to a width (LVGL labels WRAP overflow into the next row)
local function fit(txt, max_w, font)
    txt = tostring(txt or "")
    if txt == "" then return txt end
    font = font or SMLSIZE
    if lcd.sizeText(txt, font) <= max_w then return txt end
    local n = #txt
    while n > 1 do
        n = n - 1
        local cut = string.sub(txt, 1, n) .. "."
        if lcd.sizeText(cut, font) <= max_w then return cut end
    end
    return string.sub(txt, 1, 1)
end

-- detail-page header: title left in accent, hint right, 1-px divider; the
-- title row is a tap target for "back" (the host detail pages' pattern)
local function header(fb, layout, P, W, headH, titleFont, tth, sh, title, hint, back_fn)
    local hintW = lcd.sizeText(hint, SMLSIZE) + 8
    layout[#layout + 1] = { type = "label", x = 6, y = (headH - tth) / 2,
        w = W - hintW - 12, h = tth, font = titleFont, color = P.accent,
        text = fit(title, W - hintW - 16, titleFont) }
    layout[#layout + 1] = { type = "label", x = 6, y = (headH - sh) / 2,
        w = W - 12, h = sh, font = SMLSIZE, align = RIGHT, color = P.hint, text = hint }
    layout[#layout + 1] = { type = "rectangle", filled = true,
        x = 0, y = headH - 1, w = W, h = 1, color = P.line }
    if back_fn ~= nil then add_hit(fb, 0, 0, W, headH, back_fn, 30) end
end

-- error banner under the header (write failures, spec §8); returns next y
local function banner(fb, layout, P, W, y, sh)
    if fb.err == nil then return y end
    layout[#layout + 1] = { type = "rectangle", filled = true,
        x = 0, y = y, w = W, h = sh + 6, color = P.bannerBg or P.hint }
    layout[#layout + 1] = { type = "label", x = 6, y = y + 3, w = W - 12, h = sh,
        font = SMLSIZE, color = P.bannerFg or P.bg or lcd.RGB(0, 0, 0), text = fb.err }
    return y + sh + 10
end

local PROF_VALUES = { "auto (match by capacity)", "1", "2", "3", "4", "5", "6" }

local function models_text(mm)
    if mm == nil or #mm == 0 then return "all" end
    for i = 1, #mm do
        if mm[i] == "*" then return "all" end
    end
    return table.concat(mm, ", ")
end

-- ---------------------------------------------------------------------
-- the three pages + the dialog overlay
-- ---------------------------------------------------------------------

local function build_detail_pg(wgt, zone, fb, P)
    local W, H = zone.w, zone.h
    local big = H >= 300
    local titleFont = big and MIDSIZE or SMLSIZE
    local _, tth = lcd.sizeText("Ag", titleFont)
    local _, sh = lcd.sizeText("Ag", SMLSIZE)
    local headH = tth + 8
    local b = fb.cur or {}
    local layout = {}
    if P.bg then
        layout[#layout + 1] = { type = "rectangle", filled = true, x = 0, y = 0, w = W, h = H, color = P.bg }
    end
    header(fb, layout, P, W, headH, titleFont, tth, sh, disp_name(b), "Battery",
        function(w) leave(w, w.fb) end)
    local y = banner(fb, layout, P, W, headH + (big and 8 or 4), sh)
    local row_h = sh + (big and 8 or 4)
    local lblw = math.floor(W * 0.42)
    local vw = W - lblw - 20
    local function kv(lbl, val)
        layout[#layout + 1] = { type = "label", x = 8, y = y, w = lblw, h = sh + 2,
            font = SMLSIZE, color = P.textDim, text = lbl }
        layout[#layout + 1] = { type = "label", x = 8 + lblw + 6, y = y, w = vw, h = sh + 2,
            font = SMLSIZE, color = P.text, text = val }
        y = y + row_h
    end
    kv("id", b.id or "-")
    kv("Capacity", b.cap ~= nil and (b.cap .. " mAh") or "-")
    kv("Cycles", tostring(b.cycles or 0))
    kv("Flights", tostring(flights_of(fb, b.id)))
    kv("Last use", (b.last ~= nil and b.last ~= "") and b.last or "-")
    kv("Profile", b.profile ~= nil and tostring(b.profile) or "auto (by capacity)")
    kv("Models", fit(models_text(b.models), vw))
    local btnH = big and 36 or 28
    local bw = math.min(200, math.floor((W - 36) / 2))
    local by = H - btnH - (big and 10 or 6)
    button(fb, layout, P, W - 2 * bw - 20, by, bw, btnH, "Edit", SMLSIZE,
        function(w) start_edit(w, w.fb) end)
    button(fb, layout, P, W - bw - 8, by, bw, btnH, "Delete", SMLSIZE,
        function(w)
            local fbx = w.fb
            local n = flights_of(fbx, fbx.cur and fbx.cur.id)
            fbx.dlg = { title = "Delete " .. disp_name(fbx.cur) .. "?", ok_txt = "Delete",
                msg = (n > 0)
                    and (n .. " logged flight" .. (n == 1 and " keeps" or "s keep") .. " its id.")
                    or "No logged flights.",
                on_ok = function(w2, fb2) fb2.dlg = nil; fb2.del_req = true; w2.fb_dirty = true end }
            w.fb_dirty = true
        end)
    lvgl.build(layout)
end

local function build_form(wgt, zone, fb, P)
    local W, H = zone.w, zone.h
    local big = H >= 300
    local titleFont = big and MIDSIZE or SMLSIZE
    local _, tth = lcd.sizeText("Ag", titleFont)
    local _, sh = lcd.sizeText("Ag", SMLSIZE)
    local headH = tth + 8
    local btnH = big and 36 or 28
    local footH = btnH + (big and 12 or 8)
    local layout = {}
    if P.bg then
        layout[#layout + 1] = { type = "rectangle", filled = true, x = 0, y = 0, w = W, h = H, color = P.bg }
    end
    header(fb, layout, P, W, headH, titleFont, tth, sh,
        (fb.mode == "create") and "New battery" or "Edit battery", "Battery",
        function(w) cancel_form(w, w.fb) end)
    local y0 = banner(fb, layout, P, W, headH + (big and 6 or 3), sh)
    -- six rows must fit every zone (480x272 included): the step is derived
    local step = math.floor((H - y0 - footH - 4) / 6)
    local ctrlH = math.min(big and 36 or 28, step - 2)
    local ctrlW = math.min(240, math.floor(W * 0.48))
    local cx = W - ctrlW - 8
    local lblw = cx - 20
    local function row_y(i) return y0 + (i - 1) * step end
    local function lbl(i, txt)
        layout[#layout + 1] = { type = "label", x = 10,
            y = row_y(i) + math.floor((ctrlH - sh) / 2), w = lblw, h = sh + 2,
            font = SMLSIZE, color = P.textDim, text = txt }
    end
    lbl(1, "id")
    lbl(2, "Name")
    lbl(3, "Capacity (mAh, 0 = unset)")
    lbl(4, "Models")
    lbl(5, "FC profile")
    lbl(6, "Cycles")
    -- models row: static summary + chevron; the sub-page owns the editing
    layout[#layout + 1] = { type = "label", x = cx, y = row_y(4) + math.floor((ctrlH - sh) / 2),
        w = ctrlW - 16, h = sh + 2, font = SMLSIZE, color = P.text,
        text = fit(fb.e.models_all and "all" or models_text(fb.e.models), ctrlW - 18) }
    layout[#layout + 1] = { type = "label", x = W - 18, y = row_y(4) + math.floor((ctrlH - sh) / 2),
        w = 12, h = sh + 2, font = SMLSIZE, align = RIGHT, color = P.textDim, text = ">" }
    add_hit(fb, cx - 4, row_y(4), ctrlW + 12, ctrlH,
        function(w) w.fb.view = "models"; w.fb.mpage = 0; w.fb_dirty = true end, 30)
    -- footer: Save / Cancel (Cancel discards; only Save writes)
    local bw = math.min(180, math.floor((W - 36) / 2))
    local by = H - btnH - (big and 8 or 5)
    button(fb, layout, P, W - 2 * bw - 20, by, bw, btnH, "Save", SMLSIZE,
        function(w) on_save(w, w.fb) end)
    button(fb, layout, P, W - bw - 8, by, bw, btnH, "Cancel", SMLSIZE,
        function(w) cancel_form(w, w.fb) end)
    lvgl.build(layout)

    -- With a dialog up, the page below is INERT: the dialog took the hit list,
    -- and the focusable controls must not be built either -- an LVGL control
    -- under the overlay would still open its keyboard on a tap
    if fb.dlg ~= nil then return end

    -- Focusable controls LAST, over the static layout (logview's textEdit
    -- order). Each is pcall-guarded; numberEdit is 2.11+ and FULLSCREEN-ONLY
    -- (fine here -- tool pages are fullscreen), its ctor returns nil elsewhere,
    -- and it takes NO step=/value= keys (spike 2026-08-17): get/set only,
    -- `set` fires on EVERY keypress. Fallback: textEdit + numeric validation.
    pcall(function()
        lvgl.textEdit({ x = cx, y = row_y(1), w = ctrlW, h = ctrlH,
            value = fb.e.id, length = 24,
            set = function(s)
                fb.e.id = M.sanitize_id(s)
                wgt.fb_dirty = true      -- re-show the sanitised value
            end })
    end)
    pcall(function()
        lvgl.textEdit({ x = cx, y = row_y(2), w = ctrlW, h = ctrlH,
            value = fb.e.name, length = 24,
            set = function(s)
                fb.e.name = M.sanitize_name(s)
                wgt.fb_dirty = true
            end })
    end)
    local function num_field(rowi, key, maxv)
        local ok = pcall(function()
            local ne = lvgl.numberEdit({ x = cx, y = row_y(rowi), w = ctrlW, h = ctrlH,
                min = 0, max = maxv,
                get = function() return fb.e[key] end,
                set = function(v)
                    if type(v) == "number" then fb.e[key] = math.floor(v) end
                end })
            if ne == nil then error("no numberEdit") end
        end)
        if not ok then
            -- named fallback (spec S3): plain textEdit, digits validated in set
            pcall(function()
                lvgl.textEdit({ x = cx, y = row_y(rowi), w = ctrlW, h = ctrlH,
                    value = tostring(fb.e[key]), length = 5,
                    set = function(s)
                        local n = tonumber(string.match(tostring(s or ""), "%d+") or "")
                        if n ~= nil then
                            if n > maxv then n = maxv end
                            fb.e[key] = math.floor(n)
                        end
                        wgt.fb_dirty = true
                    end })
            end)
        end
    end
    num_field(3, "cap", 30000)
    num_field(6, "cycles", 9999)
    local okch = pcall(function()
        local ch = lvgl.choice({ x = cx, y = row_y(5), w = ctrlW, h = ctrlH,
            title = "FC profile", values = PROF_VALUES,
            get = function() return (fb.e.profile or 0) + 1 end,
            set = function(i) fb.e.profile = i - 1 end })
        if ch == nil then error("no choice") end
    end)
    if not okch then
        -- fallback: a cycle button (the settings pages' own choice fallback)
        local fl2 = {}
        button(fb, fl2, P, cx, row_y(5), ctrlW, ctrlH,
            PROF_VALUES[(fb.e.profile or 0) + 1], SMLSIZE,
            function(w)
                w.fb.e.profile = ((w.fb.e.profile or 0) + 1) % 7
                w.fb_dirty = true
            end)
        lvgl.build(fl2)
    end
end

local function build_models(wgt, zone, fb, P)
    local W, H = zone.w, zone.h
    local big = H >= 300
    local titleFont = big and MIDSIZE or SMLSIZE
    local _, tth = lcd.sizeText("Ag", titleFont)
    local _, sh = lcd.sizeText("Ag", SMLSIZE)
    local headH = tth + 8
    local layout = {}
    if P.bg then
        layout[#layout + 1] = { type = "rectangle", filled = true, x = 0, y = 0, w = W, h = H, color = P.bg }
    end
    -- back applies the selection to the FORM (Save applies it to the file)
    header(fb, layout, P, W, headH, titleFont, tth, sh, "Models", "Battery",
        function(w) w.fb.view = "form"; w.fb_dirty = true end)
    local row_h = sh + (big and 10 or 6)
    local editH = big and 36 or 28
    local y = headH + (big and 8 or 4)
    local box = sh - 2
    local function check_row(cy, txt, on, fn)
        layout[#layout + 1] = { type = "rectangle", x = 10, y = cy + math.floor((row_h - box) / 2),
            w = box, h = box, thickness = 1, color = P.textDim }
        if on then
            layout[#layout + 1] = { type = "rectangle", filled = true,
                x = 13, y = cy + math.floor((row_h - box) / 2) + 3,
                w = box - 6, h = box - 6, color = P.accent }
        end
        layout[#layout + 1] = { type = "label", x = 10 + box + 8,
            y = cy + math.floor((row_h - sh) / 2), w = W - box - 30, h = sh + 2,
            font = SMLSIZE, color = P.text, text = fit(txt, W - box - 34) }
        add_hit(fb, 4, cy, W - 8, row_h, fn, 30)
    end
    -- 1) All models = the models field is omitted from the line (parser: all)
    check_row(y, "All models", fb.e.models_all, function(w)
        local e = w.fb.e
        e.models_all = not e.models_all
        w.fb.models_touched = true
        w.fb_dirty = true
    end)
    y = y + row_h + 4
    if not fb.e.models_all then
        -- 2) union of the names seen in flights.csv, the connected craft and
        -- the entry's own assignments; stored as shown, matched case-insens.
        local cand, seen = {}, {}
        local known = fb.ctx.known_models or {}
        for i = 1, #known do
            local m = trim(known[i])
            local k = string.lower(m)
            if m ~= "" and not seen[k] then seen[k] = true; cand[#cand + 1] = m end
        end
        for i = 1, #fb.e.models do
            local k = string.lower(fb.e.models[i])
            if not seen[k] then seen[k] = true; cand[#cand + 1] = fb.e.models[i] end
        end
        local have = {}
        for i = 1, #fb.e.models do have[string.lower(fb.e.models[i])] = i end
        -- paging (spec §9's watch point): bounded by distinct model names
        local avail = H - y - editH - row_h - 12
        local vis = math.max(1, math.floor(avail / row_h))
        local pages = math.max(1, math.ceil(#cand / vis))
        if (fb.mpage or 0) > pages - 1 then fb.mpage = pages - 1 end
        local first = (fb.mpage or 0) * vis
        for i = first + 1, math.min(#cand, first + vis) do
            local nm = cand[i]
            check_row(y, nm, have[string.lower(nm)] ~= nil, function(w)
                local e = w.fb.e
                local k = string.lower(nm)
                local at = nil
                for j = 1, #e.models do
                    if string.lower(e.models[j]) == k then at = j break end
                end
                if at ~= nil then table.remove(e.models, at) else e.models[#e.models + 1] = nm end
                w.fb.models_touched = true
                w.fb_dirty = true
            end)
            y = y + row_h
        end
        if pages > 1 then
            local bw = big and 56 or 44
            local py = H - editH - row_h - 6
            layout[#layout + 1] = { type = "label", x = W - 2 * bw - 90,
                y = py + math.floor((row_h - sh) / 2), w = 76, h = sh + 2,
                font = SMLSIZE, align = RIGHT, color = P.textDim,
                text = ((fb.mpage or 0) + 1) .. "/" .. pages }
            button(fb, layout, P, W - 2 * bw - 10, py, bw, row_h - 2, "<", SMLSIZE,
                function(w)
                    if (w.fb.mpage or 0) > 0 then w.fb.mpage = w.fb.mpage - 1; w.fb_dirty = true end
                end)
            button(fb, layout, P, W - bw - 4, py, bw, row_h - 2, ">", SMLSIZE,
                function(w)
                    w.fb.mpage = (w.fb.mpage or 0) + 1
                    w.fb_dirty = true
                end)
        end
    end
    -- 3) free-text entry for a model never seen (spec B10); comma stripped
    local ey = H - editH - 6
    layout[#layout + 1] = { type = "label", x = 10, y = ey + math.floor((editH - sh) / 2),
        w = 110, h = sh + 2, font = SMLSIZE, color = P.textDim, text = "Enter name..." }
    lvgl.build(layout)
    local ex = 124
    pcall(function()
        lvgl.textEdit({ x = ex, y = ey, w = W - ex - 8, h = editH,
            value = "", length = 32,
            set = function(s)
                local m = M.sanitize_model(s)
                if m ~= "" then
                    local e = fb.e
                    local k = string.lower(m)
                    local dup = false
                    for j = 1, #e.models do
                        if string.lower(e.models[j]) == k then dup = true break end
                    end
                    if not dup then e.models[#e.models + 1] = m end
                    e.models_all = false
                    fb.models_touched = true
                end
                wgt.fb_dirty = true
            end })
    end)
end

-- small confirm/message overlay (logview's dialog idiom, reduced): it takes
-- the page's tap targets with it, so the page below is inert
local function build_dlg(wgt, zone, fb, P)
    local d = fb.dlg
    local W, H = zone.w, zone.h
    local big = H >= 300
    local _, sh = lcd.sizeText("Ag", SMLSIZE)
    local font = big and MIDSIZE or SMLSIZE
    local _, th = lcd.sizeText("Ag", font)
    local btnH = big and 36 or 28
    local pw = math.min(W - 40, 380)
    local msgH = 3 * sh                       -- room for a wrapped message
    local ph = th + 10 + msgH + 10 + btnH + 10
    if ph > H - 8 then ph = H - 8 end
    local px = math.floor((W - pw) / 2)
    local py = math.floor((H - ph) / 2)
    fb.hit = {}                               -- the dialog owns every tap now
    local layout = {}
    layout[#layout + 1] = { type = "rectangle", filled = true, x = px, y = py,
        w = pw, h = ph, color = P.bg or lcd.RGB(0, 0, 0) }
    layout[#layout + 1] = { type = "rectangle", x = px, y = py, w = pw, h = ph,
        thickness = 1, rounded = 4, color = P.line }
    layout[#layout + 1] = { type = "label", x = px + 12, y = py + 6, w = pw - 24, h = th,
        font = font, color = P.accent, text = d.title or "" }
    layout[#layout + 1] = { type = "label", x = px + 12, y = py + th + 12,
        w = pw - 24, h = msgH, font = SMLSIZE, color = P.text, text = d.msg or "" }
    local byy = py + ph - btnH - 8
    if d.only_ok then
        button(fb, layout, P, px + 12, byy, pw - 24, btnH, "OK", SMLSIZE,
            function(w) w.fb.dlg = nil; w.fb_dirty = true end)
    else
        local bw = math.floor((pw - 36) / 2)
        button(fb, layout, P, px + 12, byy, bw, btnH, "Cancel", SMLSIZE,
            function(w) w.fb.dlg = nil; w.fb_dirty = true end)
        button(fb, layout, P, px + pw - 12 - bw, byy, bw, btnH, d.ok_txt or "OK", SMLSIZE,
            function(w) d.on_ok(w, w.fb) end)
    end
    lvgl.build(layout)
end

function M.build(wgt, zone)
    local fb = wgt.fb
    if fb == nil then return end
    fb.hit = {}
    local P = palette(wgt)
    if fb.view == "form" then
        build_form(wgt, zone, fb, P)
    elseif fb.view == "models" then
        build_models(wgt, zone, fb, P)
    else
        build_detail_pg(wgt, zone, fb, P)
    end
    if fb.dlg ~= nil then build_dlg(wgt, zone, fb, P) end
end

-- ---------------------------------------------------------------------
-- refresh: armed gate, the deferred write cycle, tap dispatch
-- ---------------------------------------------------------------------

local function rect_hit(ts, r)
    return ts ~= nil and ts.x ~= nil
        and ts.x >= r.x and ts.x < r.x + r.w
        and ts.y >= r.y and ts.y < r.y + r.h
end

function M.refresh(wgt, event, touch_state)
    local fb = wgt.fb
    if fb == nil then return end
    -- disarmed-only (spec 6.4): arming closes every page and DISCARDS an open
    -- form -- nothing is written (only the deferred requests below ever write).
    -- In the viewer flow the Flight Log's own arm close runs first; this is
    -- the battpick flow's gate (and defense in depth for the other).
    if wgt.armed_now then
        M.close(wgt)
        wgt.fb_close_req = true
        return
    end
    if lvgl.isFullScreen ~= nil and not lvgl.isFullScreen() then
        M.close(wgt)
        wgt.fb_close_req = true
        return
    end
    -- registry writes get their OWN cycle (the Toolbox io rule): the tap only
    -- requested them, this cycle does nothing else
    if fb.save_req then
        fb.save_req = nil
        do_save(wgt, fb)
        return
    end
    if fb.del_req then
        fb.del_req = nil
        do_delete(wgt, fb)
        return
    end
    local now = getTime() or 0
    if EVT_TOUCH_TAP ~= nil and event == EVT_TOUCH_TAP and touch_state ~= nil
        and (touch_state.tapCount == nil or touch_state.tapCount <= 1)
        and now >= (fb.tap_block or 0) then
        local hits = fb.hit
        for i = 1, #hits do
            local r = hits[i]
            if rect_hit(touch_state, r) then
                fb.tap_block = now + (r.cool or 30)
                r.fn(wgt, touch_state)
                break
            end
        end
    end
end

-- RTN: true = consumed internally, false = at the top (the caller closes).
-- Form-level RTN is Cancel -- the working copy is discarded outright, which
-- is what makes the numberEdit commit-on-RTN harmless (see the header).
function M.on_exit_key(wgt)
    local fb = wgt.fb
    if fb == nil then return false end
    if fb.dlg ~= nil then
        fb.dlg = nil
        wgt.fb_dirty = true
        return true
    end
    if fb.view == "models" then
        fb.view = "form"          -- back applies the selection to the form
        wgt.fb_dirty = true
        return true
    end
    if fb.view == "form" and fb.mode == "edit" then
        cancel_form(wgt, fb)      -- back to the detail, working copy dropped
        return true
    end
    return false                  -- detail / create form: caller closes
end

return M
