script_name('ARIZONA PAYDAY BOT PL')
script_author('SHEWA')
script_version('1.4.5')

local inicfg = require 'inicfg'
local encoding = require 'encoding'
local ev = require 'samp.events'
local imgui = require 'imgui' -- MoonLoader legacy ImGui
encoding.default = 'CP1251'
local u8 = encoding.UTF8
local configName = 'arizona_payday_pl'
local MANIFEST_URL = 'https://raw.githubusercontent.com/xromxgame-lgtm/ARIZONA-PAYDAY-BOT/main/manifest.txt'
local updateState = 'Ожидание проверки обновлений'
local lastUpdateCheck = 0
local updateNoticeVersion = nil
local updateInfo, updateBusy = nil, false
local defaults={main={bot_token='',chat_id='',auto_send=true,settle_seconds=15}}
local cfg=inicfg.load(defaults,configName) or defaults
cfg.main=cfg.main or defaults.main
local window = imgui.ImBool(false)
local token = imgui.ImBuffer(256)
local chatid = imgui.ImBuffer(64)
local auto = imgui.ImBool(cfg.main.auto_send)
local active,last,lastAt = nil,nil,0
local history = {}
local diagnostic = 'Ожидаем настоящий Payday от сервера'
local sending = false

local function save() inicfg.save(cfg,configName) end
local function note(s)
  -- SA:MP chat requires CP1251, unlike ImGui and Telegram (UTF-8).
  local raw = tostring(s)
  local ok, cp = pcall(function() return u8:encode(raw) end)
  sampAddChatMessage('[PAYDAY PL] '..(ok and cp or raw), 0xFF5566)
end
local function clean(s) return (s or ''):gsub('{%x%x%x%x%x%x}',''):gsub('~[%a]~','') end
local function num(s)
  -- Only a money value explicitly marked with $; ignore dates, IDs and XP.
  local a=s:match('%$%s*([%d][%d%s%,%.]*)') or s:match('([%d][%d%s%,%.]*)%s*%$')
  if not a then return nil end
  return tonumber((a:gsub('[^%d]','')))
end
local function lowerRu(s)
  local t={}
  for i=0,31 do
    local upper= (i<16 and string.char(0xD0,0x90+i) or string.char(0xD0,0x90+i))
    -- Cyrillic uppercase А-Я (UTF-8 D0 90..AF), lowercase а-п (D0 B0..BF), р-я (D1 80..8F)
    local low= i<16 and string.char(0xD0,0xB0+i) or string.char(0xD1,0x80+i-16)
    t[upper]=low
  end
  t['Ё']='ё'
  return (s:lower():gsub('[\208\209][\128-\191]', function(c) return t[c] or c end))
end
local function multiplier(s)
  local l=lowerRu(s)
  local n=l:match('[xх]%s*([1234])') or l:match('([1234])%s*[xх]')
  return tonumber(n)
end
local function kind(s)
  local l=lowerRu(s)
  if l:find('налог',1,true) or l:find('аренд',1,true) or l:find('списан',1,true) then return 'tax' end
  if l:find('бонус',1,true) or l:find('преми',1,true) then return 'bonus' end
  if l:find('зарплат',1,true) or l:find('заработ',1,true) then return 'salary' end
end
local function totals(r)
  local salary,bonus,tax=0,0,0
  for _,v in ipairs(r.items) do
    if v.kind=='salary' then salary=salary+v.amount elseif v.kind=='bonus' then bonus=bonus+v.amount else tax=tax+v.amount end
  end
  return salary,bonus,tax
end
local function money(n)
  local v=tostring(math.floor(tonumber(n) or 0))
  return v:reverse():gsub('(%d%d%d)','%1 '):reverse():gsub('^ ','')
end
local function summary(r)
  local salary,bonus,tax=totals(r)
  local t={'🔴 SHEWA | PAYDAY SYSTEM', '━━━━━━━━━━━━━━━━━━━━', '🎮 ARIZONA RP • ФИНАНСОВЫЙ ОТЧЁТ', '🕒 '..r.time}
  if r.mult then table.insert(t,'⚡ Множитель: X'..r.mult) else table.insert(t,'⚡ Множитель: не подтверждён') end
  if salary>0 then table.insert(t,'💵 Зарплата: $'..money(salary)) end
  if bonus>0 then table.insert(t,'🎁 Бонусы: +$'..money(bonus)) end
  if tax>0 then table.insert(t,'💸 Удержания: −$'..money(tax)) end
  table.insert(t,'━━━━━━━━━━━━━━━━━━━━')
  table.insert(t,'💰 СУММА ОБНАРУЖЕННЫХ НАЧИСЛЕНИЙ: $'..money(salary+bonus-tax))
  table.insert(t,'ℹ️ Только суммы из сообщений сервера; баланс счёта не проверен.')
  return table.concat(t,'\\n')
end
local function urlenc(s) return (s:gsub('([^%w%-_%.~])',function(c) return ('%%%02X'):format(c:byte()) end)) end
local function send(text)
  if sending then note('Отправка в Telegram...');return end
  if tostring(cfg.main.bot_token or '')=='' or tostring(cfg.main.chat_id or '')=='' then note('Укажи токен и Chat ID в /pl');return end
  sending=true
  lua_thread.create(function()
    local ok,err=pcall(function()
      local https=require 'ssl.https'
      local ltn12=require 'ltn12'
      local payload='chat_id='..urlenc(tostring(cfg.main.chat_id))..'&text='..urlenc(text)
      local chunks={}
      local _,status=https.request({url='https://api.telegram.org/bot'..tostring(cfg.main.bot_token)..'/sendMessage',method='POST',headers={['content-type']='application/x-www-form-urlencoded',['content-length']=tostring(#payload)},source=ltn12.source.string(payload),sink=ltn12.sink.table(chunks)})
      if tonumber(status)~=200 then error('Telegram HTTP '..tostring(status)) end
      if not table.concat(chunks):find('"ok"%s*:%s*true') then error('Telegram API rejected message') end
    end)
    sending=false
    if ok then note('Отчёт отправлен в Telegram') else note('Ошибка отправки Telegram') end
  end)
end
local function finish()
  if not active then return end
  local r=active; active=nil
  if #r.items==0 then diagnostic='Payday замечен, но подтверждённых сумм нет'; return end
  last=r
  table.insert(history,1,r)
  if #history>20 then table.remove(history) end
  local f=io.open(getWorkingDirectory()..'/config/arizona_payday_pl_history.txt','a')
  if f then f:write('\n'..summary(r)..'\n');f:close() end
  if cfg.main.auto_send then send(summary(r)) end
  diagnostic='Payday записан: '..r.time
  note('Payday записан. Открой /pl')
end
function ev.onServerMessage(color,text)
  local raw=clean(text)
  local ok,s=pcall(function() return u8:decode(raw) end)
  if not ok or type(s)~='string' then return end
  local l=lowerRu(s)
  if l:find('payday',1,true) or l:find('пейдей',1,true) or l:find('пэйдей',1,true) then
    if active and #active.items>0 then finish() end
    active={time=os.date('%Y-%m-%d %H:%M:%S'),mult=multiplier(s),items={}}
    lastAt=os.time()
    diagnostic='Payday обнаружен, собираю начисления'
    return
  end
  if not active then return end
  local m=multiplier(s)
  if m and (l:find('множител',1,true) or l:find('payday',1,true) or l:find('пейдей',1,true) or l:find('пэйдей',1,true) or l:find('зарплат',1,true)) then active.mult=m end
  local amount=num(s)
  local k=kind(s)
  if amount and amount > 0 and k and (l:find('
    table.insert(active.items,{kind=k,amount=amount,text=s})
    lastAt=os.time()
    diagnostic='Получена строка начисления: '..k
  end
end
local function fill()
  token.v=tostring(cfg.main.bot_token or '')
  chatid.v=tostring(cfg.main.chat_id or '')
  auto.v=cfg.main.auto_send
end
local function saveForm()
  local id=tostring(chatid.v)
  if id~='' and not id:match('^%-?%d+$') then note('Chat ID must contain digits only');return end
  cfg.main.bot_token=tostring(token.v)
  cfg.main.chat_id=id
  cfg.main.auto_send=auto.v
  save()
  note('Settings saved')
end
function imgui.OnInitialize()
  local io = imgui.GetIO()
  local path = getFolderPath(0x14) .. [[\arial.ttf]]
  if doesFileExist(path) then
    io.Fonts:AddFontFromFileTTF(path, 17, nil, io.Fonts:GetGlyphRangesCyrillic())
  end
end

local function theme()
  local st = imgui.GetStyle()
  st.WindowRounding = 12
  st.WindowBorderSize = 2
  st.ChildWindowRounding = 9
  st.FrameRounding = 7
  st.GrabRounding = 7
  st.ScrollbarRounding = 8
  st.WindowPadding = imgui.ImVec2(18, 15)
  st.FramePadding = imgui.ImVec2(10, 7)
  st.ItemSpacing = imgui.ImVec2(10, 9)
  local c = st.Colors
  local C = imgui.Col
  local function rgba(r,g,b,a) return imgui.ImVec4(r/255,g/255,b/255,a or 1) end
  c[C.WindowBg] = rgba(8,8,12,1)
  c[C.ChildWindowBg] = rgba(15,15,20,1)
  c[C.Text] = rgba(238,239,242)
  c[C.TextDisabled] = rgba(145,147,156)
  c[C.Border] = rgba(105,35,45,.65)
  c[C.FrameBg] = rgba(30,31,39)
  c[C.FrameBgHovered] = rgba(56,36,45)
  c[C.FrameBgActive] = rgba(78,35,45)
  c[C.TitleBg] = rgba(23,19,25)
  c[C.TitleBgActive] = rgba(75,20,32)
  c[C.CheckMark] = rgba(255,66,84)
  c[C.Button] = rgba(144,29,47)
  c[C.ButtonHovered] = rgba(214,45,64)
  c[C.ButtonActive] = rgba(255,69,82)
  c[C.Header] = rgba(115,27,42)
  c[C.HeaderHovered] = rgba(175,40,58)
  c[C.HeaderActive] = rgba(218,49,65)
  c[C.Separator] = rgba(130,39,54)
  c[C.ResizeGrip] = rgba(145,35,48,.7)
  c[C.ResizeGripHovered] = rgba(211,50,68)
  c[C.ResizeGripActive] = rgba(255,70,85)
end

local function accent(text)
  imgui.TextColored(imgui.ImVec4(1,.27,.34,1), text)
end

local function animatedLine()
  -- The line pulses gently; no external textures or downloads needed.
  local pulse = (math.sin(os.clock()*2.3)+1)/2
  imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(.32+.43*pulse,.065,.11,1))
  imgui.Button('##neon', imgui.ImVec2(-1, 3))
  imgui.PopStyleColor()
end

local function trustedUrl(url)
  if type(url)~='string' then return false end
  local host=url:match('^https://([^/]+)/')
  return host=='raw.githubusercontent.com'
end
local function fetch(url)
  if not trustedUrl(url) then error('Разрешены только HTTPS-ссылки GitHub') end
  local https=require 'ssl.https'
  local ltn12=require 'ltn12'
  local chunks={}
  local _,status=https.request({url=url,sink=ltn12.sink.table(chunks)})
  if tonumber(status)~=200 then error('HTTP '..tostring(status)) end
  local body=table.concat(chunks)
  if #body>2*1024*1024 then error('Файл слишком большой') end
  return body
end
local function versionParts(s)
  local a,b,c=tostring(s):match('^(%d+)%.(%d+)%.?(%d*)')
  if not a then return nil end
  return tonumber(a)*1000000+tonumber(b)*1000+(tonumber(c) or 0)
end
local function checkUpdate()
  if updateBusy then return end
  local url=MANIFEST_URL
  if url=='' then updateState='Укажи ссылку на manifest.txt из GitHub';return end
  if not trustedUrl(url) then updateState='Нужна HTTPS-ссылка GitHub';return end
  updateBusy=true; lastUpdateCheck=os.time(); updateState='Проверяю обновления...' 
  lua_thread.create(function()
    local ok,err=pcall(function()
      local body=fetch(url)
      local ver,hash,download=body:match('^%s*([^|\r\n]+)|([a-fA-F0-9]+)|([^\r\n]+)')
      if not ver or not hash or #hash~=64 or not trustedUrl(download) then error('Неверный manifest.txt') end
      if not versionParts(ver) then error('Неверная версия') end
      if versionParts(ver)>versionParts('1.4.5') then
        updateInfo={version=ver,sha=hash:lower(),url=download}
        updateState='Доступна новая версия '..ver..'! Нажми УСТАНОВИТЬ.'
        if updateNoticeVersion~=ver then note('Доступна версия '..ver..'. Открой /pl'); updateNoticeVersion=ver end
      else updateInfo=nil;updateState='Установлена актуальная версия (GitHub: '..ver..')' end
    end)
    if not ok then updateInfo=nil;updateState='Ошибка проверки: '..tostring(err):sub(1,110) end
    note(ok and (updateInfo and ('Доступно обновление '..updateInfo.version) or 'Обновлений нет') or 'Ошибка проверки обновлений. Открой /pl')
    updateBusy=false
  end)
end
local function installUpdate()
  if updateBusy or not updateInfo then return end
  local info=updateInfo
  updateBusy=true;updateState='Скачиваю и проверяю SHA-256...'
  lua_thread.create(function()
    local ok,err=pcall(function()
      local data=fetch(info.url)
      if #data<100 or #data>2*1024*1024 then error('Неверный размер файла') end
      if not data:find("script_name('ARIZONA PAYDAY BOT PL')",1,true) then error('Неизвестный Lua-скрипт. Установка отменена') end
      local path=thisScript().path
      local tmp=path..'.new'
      local f=assert(io.open(tmp,'wb'));f:write(data);f:close()
      -- Windows certutil вычисляет SHA256, не выполняя загруженный код.
      local cmd='certutil -hashfile "'..tmp..'" SHA256'
      local pipe=assert(io.popen(cmd,'r'))
      local output=pipe:read('*a');pipe:close()
      local hash=output:match('([a-fA-F0-9][a-fA-F0-9%s]+)')
      local verified=false
      for line in output:gmatch('[^\r\n]+') do
        local h=line:gsub('%s','')
        if #h==64 and h:lower()==info.sha then verified=true end
      end
      if not verified then os.remove(tmp);error('SHA-256 не совпадает. Установка отменена') end
      local backup=path..'.bak'
      os.remove(backup)
      if not os.rename(path,backup) then error('Не удалось создать резервную копию') end
      if not os.rename(tmp,path) then os.rename(backup,path);error('Не удалось заменить скрипт') end
      updateInfo=nil
      updateState='Версия '..info.version..' установлена. Перезапусти игру.'
    end)
    if not ok then updateState='Ошибка установки: '..tostring(err):sub(1,110) end
    note(ok and 'Обновление установлено. Перезапусти игру' or 'Ошибка установки. Открой /pl')
    updateBusy=false
  end)
end


function imgui.OnDrawFrame()
  if not window.v then return end
  imgui.SetNextWindowSize(imgui.ImVec2(640, 590), imgui.Cond.FirstUseEver)
  if imgui.SetNextWindowBgAlpha then imgui.SetNextWindowBgAlpha(1.0) end
  imgui.Begin('ARIZONA  |  PAYDAY BOT  |  /pl', window)
  animatedLine()
  accent('A R I Z O N A    /    P A Y D A Y')
  imgui.TextDisabled('GTA REDLINE  /  SHEWA EDITION  /  v1.4.4')
  imgui.Separator()
  accent('01   TELEGRAM')
  imgui.Text('Токен бота')
  imgui.PushItemWidth(-1)
  imgui.InputText('##token', token, imgui.InputTextFlags.Password)
  imgui.Text('Числовой Chat ID')
  imgui.InputText('##chat', chatid)
  imgui.PopItemWidth()
  imgui.Checkbox('Отправлять Payday автоматически', auto)
  if imgui.Button('СОХРАНИТЬ', imgui.ImVec2(170, 34)) then saveForm() end
  imgui.SameLine()
  if imgui.Button('ТЕСТ TELEGRAM', imgui.ImVec2(180, 34)) then
    saveForm()
    send('🔴 SHEWA | PAYDAY SYSTEM\\n✅ Проверка связи Telegram успешна')
  end
  imgui.Separator()
  accent('02   PAYDAY / ОТЧЁТ')
  local r=active or last
  if r then
    local salary,bonus,tax=totals(r)
    imgui.Text('Множитель: '..(r.mult and ('X'..r.mult) or 'не определён')..'   |   '..r.time)
    imgui.Text('Зарплата: $'..salary..'   Бонус: +$'..bonus..'   Налоги: -$'..tax)
    imgui.Text('Итого по сообщениям: $'..(salary+bonus-tax))
    if #r.items > 0 and imgui.Button('ОТПРАВИТЬ ОТЧЁТ', imgui.ImVec2(190, 32)) then saveForm();send(summary(r)) end
  else
    imgui.TextDisabled('Ожидаем Payday. Множитель определяется автоматически.')
  end
  imgui.TextWrapped(diagnostic)
  imgui.TextDisabled('За этот запуск записано: '..#history)
  imgui.Separator()
  accent('03   ОБНОВЛЕНИЯ')
  imgui.TextWrapped(updateState)
  imgui.TextDisabled('Автопроверка каждые 30 минут. Установка только по кнопке.')
  if imgui.Button('ПРОВЕРИТЬ ОБНОВЛЕНИЯ', imgui.ImVec2(240, 36)) then checkUpdate() end
  if updateInfo then
    imgui.SameLine()
    if imgui.Button('УСТАНОВИТЬ', imgui.ImVec2(160, 36)) then installUpdate() end
  end
  animatedLine()
  imgui.End()
  if not window.v then
    imgui.ShowCursor=false
    imgui.LockPlayer=false
  end
end

function main()
  while not isSampAvailable() do wait(200) end
  sampRegisterChatCommand('pl',function()
    window.v=not window.v
    imgui.Process=window.v
    imgui.ShowCursor=window.v
    imgui.LockPlayer=window.v
  end)
  local filled, fillErr = pcall(fill)
  if not filled then print('[PAYDAY PL] Config field error: '..tostring(fillErr)) end
  local themed, themeErr = pcall(theme)
  if not themed then print('[PAYDAY PL] Theme fallback: '..tostring(themeErr)) end
  note('Ready. Open /pl')
  checkUpdate()
  while true do
    wait(100)
    imgui.Process=window.v
    imgui.ShowCursor=window.v
    imgui.LockPlayer=window.v
    if not updateBusy and os.time()-lastUpdateCheck>=1800 then checkUpdate() end
    if active and #active.items>0 and os.time()-lastAt >= (tonumber(cfg.main.settle_seconds) or 15) then finish() end
  end
end,1,true)) then
    table.insert(active.items,{kind=k,amount=amount,text=s})
    lastAt=os.time()
    diagnostic='Получена строка начисления: '..k
  end
end
local function fill()
  token.v=tostring(cfg.main.bot_token or '')
  chatid.v=tostring(cfg.main.chat_id or '')
  auto.v=cfg.main.auto_send
end
local function saveForm()
  local id=tostring(chatid.v)
  if id~='' and not id:match('^%-?%d+$') then note('Chat ID must contain digits only');return end
  cfg.main.bot_token=tostring(token.v)
  cfg.main.chat_id=id
  cfg.main.auto_send=auto.v
  save()
  note('Settings saved')
end
function imgui.OnInitialize()
  local io = imgui.GetIO()
  local path = getFolderPath(0x14) .. [[\arial.ttf]]
  if doesFileExist(path) then
    io.Fonts:AddFontFromFileTTF(path, 17, nil, io.Fonts:GetGlyphRangesCyrillic())
  end
end

local function theme()
  local st = imgui.GetStyle()
  st.WindowRounding = 12
  st.WindowBorderSize = 2
  st.ChildWindowRounding = 9
  st.FrameRounding = 7
  st.GrabRounding = 7
  st.ScrollbarRounding = 8
  st.WindowPadding = imgui.ImVec2(18, 15)
  st.FramePadding = imgui.ImVec2(10, 7)
  st.ItemSpacing = imgui.ImVec2(10, 9)
  local c = st.Colors
  local C = imgui.Col
  local function rgba(r,g,b,a) return imgui.ImVec4(r/255,g/255,b/255,a or 1) end
  c[C.WindowBg] = rgba(8,8,12,1)
  c[C.ChildWindowBg] = rgba(15,15,20,1)
  c[C.Text] = rgba(238,239,242)
  c[C.TextDisabled] = rgba(145,147,156)
  c[C.Border] = rgba(105,35,45,.65)
  c[C.FrameBg] = rgba(30,31,39)
  c[C.FrameBgHovered] = rgba(56,36,45)
  c[C.FrameBgActive] = rgba(78,35,45)
  c[C.TitleBg] = rgba(23,19,25)
  c[C.TitleBgActive] = rgba(75,20,32)
  c[C.CheckMark] = rgba(255,66,84)
  c[C.Button] = rgba(144,29,47)
  c[C.ButtonHovered] = rgba(214,45,64)
  c[C.ButtonActive] = rgba(255,69,82)
  c[C.Header] = rgba(115,27,42)
  c[C.HeaderHovered] = rgba(175,40,58)
  c[C.HeaderActive] = rgba(218,49,65)
  c[C.Separator] = rgba(130,39,54)
  c[C.ResizeGrip] = rgba(145,35,48,.7)
  c[C.ResizeGripHovered] = rgba(211,50,68)
  c[C.ResizeGripActive] = rgba(255,70,85)
end

local function accent(text)
  imgui.TextColored(imgui.ImVec4(1,.27,.34,1), text)
end

local function animatedLine()
  -- The line pulses gently; no external textures or downloads needed.
  local pulse = (math.sin(os.clock()*2.3)+1)/2
  imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(.32+.43*pulse,.065,.11,1))
  imgui.Button('##neon', imgui.ImVec2(-1, 3))
  imgui.PopStyleColor()
end

local function trustedUrl(url)
  if type(url)~='string' then return false end
  local host=url:match('^https://([^/]+)/')
  return host=='raw.githubusercontent.com'
end
local function fetch(url)
  if not trustedUrl(url) then error('Разрешены только HTTPS-ссылки GitHub') end
  local https=require 'ssl.https'
  local ltn12=require 'ltn12'
  local chunks={}
  local _,status=https.request({url=url,sink=ltn12.sink.table(chunks)})
  if tonumber(status)~=200 then error('HTTP '..tostring(status)) end
  local body=table.concat(chunks)
  if #body>2*1024*1024 then error('Файл слишком большой') end
  return body
end
local function versionParts(s)
  local a,b,c=tostring(s):match('^(%d+)%.(%d+)%.?(%d*)')
  if not a then return nil end
  return tonumber(a)*1000000+tonumber(b)*1000+(tonumber(c) or 0)
end
local function checkUpdate()
  if updateBusy then return end
  local url=MANIFEST_URL
  if url=='' then updateState='Укажи ссылку на manifest.txt из GitHub';return end
  if not trustedUrl(url) then updateState='Нужна HTTPS-ссылка GitHub';return end
  updateBusy=true; lastUpdateCheck=os.time(); updateState='Проверяю обновления...' 
  lua_thread.create(function()
    local ok,err=pcall(function()
      local body=fetch(url)
      local ver,hash,download=body:match('^%s*([^|\r\n]+)|([a-fA-F0-9]+)|([^\r\n]+)')
      if not ver or not hash or #hash~=64 or not trustedUrl(download) then error('Неверный manifest.txt') end
      if not versionParts(ver) then error('Неверная версия') end
      if versionParts(ver)>versionParts('1.4.4') then
        updateInfo={version=ver,sha=hash:lower(),url=download}
        updateState='Доступна новая версия '..ver..'! Нажми УСТАНОВИТЬ.'
        if updateNoticeVersion~=ver then note('Update available: v'..ver..'. Open /pl'); updateNoticeVersion=ver end
      else updateInfo=nil;updateState='Установлена актуальная версия (GitHub: '..ver..')' end
    end)
    if not ok then updateInfo=nil;updateState='Ошибка проверки: '..tostring(err):sub(1,110) end
    note(ok and (updateInfo and ('Update available: '..updateInfo.version) or 'No new updates') or 'Update check failed. Open /pl')
    updateBusy=false
  end)
end
local function installUpdate()
  if updateBusy or not updateInfo then return end
  local info=updateInfo
  updateBusy=true;updateState='Скачиваю и проверяю SHA-256...'
  lua_thread.create(function()
    local ok,err=pcall(function()
      local data=fetch(info.url)
      if #data<100 or #data>2*1024*1024 then error('Неверный размер файла') end
      if not data:find("script_name('ARIZONA PAYDAY BOT PL')",1,true) then error('Неизвестный Lua-скрипт. Установка отменена') end
      local path=thisScript().path
      local tmp=path..'.new'
      local f=assert(io.open(tmp,'wb'));f:write(data);f:close()
      -- Windows certutil вычисляет SHA256, не выполняя загруженный код.
      local cmd='certutil -hashfile "'..tmp..'" SHA256'
      local pipe=assert(io.popen(cmd,'r'))
      local output=pipe:read('*a');pipe:close()
      local hash=output:match('([a-fA-F0-9][a-fA-F0-9%s]+)')
      local verified=false
      for line in output:gmatch('[^\r\n]+') do
        local h=line:gsub('%s','')
        if #h==64 and h:lower()==info.sha then verified=true end
      end
      if not verified then os.remove(tmp);error('SHA-256 не совпадает. Установка отменена') end
      local backup=path..'.bak'
      os.remove(backup)
      if not os.rename(path,backup) then error('Не удалось создать резервную копию') end
      if not os.rename(tmp,path) then os.rename(backup,path);error('Не удалось заменить скрипт') end
      updateInfo=nil
      updateState='Версия '..info.version..' установлена. Перезапусти игру.'
    end)
    if not ok then updateState='Ошибка установки: '..tostring(err):sub(1,110) end
    note(ok and 'Update installed; restart game' or 'Update install failed; see /pl')
    updateBusy=false
  end)
end


function imgui.OnDrawFrame()
  if not window.v then return end
  imgui.SetNextWindowSize(imgui.ImVec2(640, 590), imgui.Cond.FirstUseEver)
  if imgui.SetNextWindowBgAlpha then imgui.SetNextWindowBgAlpha(1.0) end
  imgui.Begin('ARIZONA  |  PAYDAY BOT  |  /pl', window)
  animatedLine()
  accent('A R I Z O N A    /    P A Y D A Y')
  imgui.TextDisabled('GTA REDLINE  /  SHEWA EDITION  /  v1.4.4')
  imgui.Separator()
  accent('01   TELEGRAM')
  imgui.Text('Токен бота')
  imgui.PushItemWidth(-1)
  imgui.InputText('##token', token, imgui.InputTextFlags.Password)
  imgui.Text('Числовой Chat ID')
  imgui.InputText('##chat', chatid)
  imgui.PopItemWidth()
  imgui.Checkbox('Отправлять Payday автоматически', auto)
  if imgui.Button('СОХРАНИТЬ', imgui.ImVec2(170, 34)) then saveForm() end
  imgui.SameLine()
  if imgui.Button('ТЕСТ TELEGRAM', imgui.ImVec2(180, 34)) then
    saveForm()
    send('ARIZONA PAYDAY BOT: test connection')
  end
  imgui.Separator()
  accent('02   PAYDAY / ОТЧЁТ')
  local r=active or last
  if r then
    local salary,bonus,tax=totals(r)
    imgui.Text('Множитель: '..(r.mult and ('X'..r.mult) or 'не определён')..'   |   '..r.time)
    imgui.Text('Зарплата: $'..salary..'   Бонус: +$'..bonus..'   Налоги: -$'..tax)
    imgui.Text('Итого по сообщениям: $'..(salary+bonus-tax))
    if #r.items > 0 and imgui.Button('ОТПРАВИТЬ ОТЧЁТ', imgui.ImVec2(190, 32)) then saveForm();send(summary(r)) end
  else
    imgui.TextDisabled('Ожидаем Payday. Множитель определяется автоматически.')
  end
  imgui.TextWrapped(diagnostic)
  imgui.TextDisabled('За этот запуск записано: '..#history)
  imgui.Separator()
  accent('03   ОБНОВЛЕНИЯ')
  imgui.TextWrapped(updateState)
  imgui.TextDisabled('Автопроверка каждые 30 минут. Установка только по кнопке.')
  if imgui.Button('ПРОВЕРИТЬ ОБНОВЛЕНИЯ', imgui.ImVec2(240, 36)) then checkUpdate() end
  if updateInfo then
    imgui.SameLine()
    if imgui.Button('УСТАНОВИТЬ', imgui.ImVec2(160, 36)) then installUpdate() end
  end
  animatedLine()
  imgui.End()
  if not window.v then
    imgui.ShowCursor=false
    imgui.LockPlayer=false
  end
end

function main()
  while not isSampAvailable() do wait(200) end
  sampRegisterChatCommand('pl',function()
    window.v=not window.v
    imgui.Process=window.v
    imgui.ShowCursor=window.v
    imgui.LockPlayer=window.v
  end)
  local filled, fillErr = pcall(fill)
  if not filled then print('[PAYDAY PL] Config field error: '..tostring(fillErr)) end
  local themed, themeErr = pcall(theme)
  if not themed then print('[PAYDAY PL] Theme fallback: '..tostring(themeErr)) end
  note('Ready. Open /pl')
  checkUpdate()
  while true do
    wait(100)
    imgui.Process=window.v
    imgui.ShowCursor=window.v
    imgui.LockPlayer=window.v
    if not updateBusy and os.time()-lastUpdateCheck>=1800 then checkUpdate() end
    if active and #active.items>0 and os.time()-lastAt >= (tonumber(cfg.main.settle_seconds) or 15) then finish() end
  end
end