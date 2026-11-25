script_name('ARIZONA PAYDAY BOT PL')
script_author('SHEWA')
script_version('1.5.2')

local inicfg = require 'inicfg'
local encoding = require 'encoding'
local ev = require 'samp.events'
local imgui = require 'imgui' -- MoonLoader legacy ImGui
encoding.default = 'CP1251'
local u8 = encoding.UTF8
local configName = 'arizona_payday_pl'
local MANIFEST_URL = 'https://raw.githubusercontent.com/xromxgame-lgtm/ARIZONA-PAYDAY-BOT/main/manifest.txt'
local RELEASE_URL = 'https://raw.githubusercontent.com/xromxgame-lgtm/ARIZONA-PAYDAY-BOT/main/arizona_payday_pl.lua'
local VERSION = '1.5.2'
local UPDATE_INTERVAL = 20
local reloadPending = false
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
local historyPath = getWorkingDirectory()..'/config/arizona_payday_pd_totals.tsv'
local lastPaydayAt
local diagnostic = 'Ожидаем настоящий Payday от сервера'
local sending = false

local function save() inicfg.save(cfg,configName) end
local function note(s)
  -- SA:MP chat requires CP1251, unlike ImGui and Telegram (UTF-8).
  local raw = tostring(s)
  local ok, cp = pcall(function() return u8:decode(raw) end)
  sampAddChatMessage('[PAYDAY PL] '..(ok and cp or raw), 0xFF5566)
end
local function clean(s) return (s or ''):gsub('{%x%x%x%x%x%x}',''):gsub('~[%a]~','') end
local function num(s)
  -- Only a money value explicitly marked with $; ignore dates, IDs and XP.
  local a=s:match(':CASH:%s*([%d][%d%s%,%.]*)') or s:match('%$%s*([%d][%d%s%,%.]*)') or s:match('([%d][%d%s%,%.]*)%s*%$')
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
  l=l:gsub('х','x')
  local n=l:match('x%s*([1234])%f[^%d]') or l:match('%f[%d]([1234])%s*x')
  return tonumber(n)
end
local function kind(s)
  local l=lowerRu(s)
  if l:find('налог',1,true) or l:find('аренд',1,true) or l:find('списан',1,true) then return 'tax' end
  if l:find('бонус',1,true) or l:find('преми',1,true) or l:find('в банде',1,true) then return 'bonus' end
  if l:find('зарплат',1,true) or l:find('заработ',1,true) then return 'salary' end
end
local function totals(r)
  if r.saved then return r.salary,r.bonus,r.tax end
  local salary,bonus,tax=0,0,0
  for _,v in ipairs(r.items) do
    if v.kind=='salary' then salary=salary+v.amount elseif v.kind=='bonus' then bonus=bonus+v.amount else tax=tax+v.amount end
  end
  return salary,bonus,tax
end
local function loadHistory()
  local f=io.open(historyPath,'r')
  if not f then return end
  for line in f:lines() do
    local stamp,m,s,b,t=line:match('^(%d+)\t(%d+)\t(%d+)\t(%d+)\t(%d+)$')
    if stamp then
      stamp=tonumber(stamp)
      local r={at=stamp,time=os.date('%Y-%m-%d %H:%M:%S',stamp),mult=tonumber(m)~=0 and tonumber(m) or nil,salary=tonumber(s),bonus=tonumber(b),tax=tonumber(t),saved=true,items={}}
      table.insert(history,1,r)
      last=r; lastPaydayAt=stamp
    end
  end
  f:close()
end
local function stats(days)
  local now=os.date('*t')
  now.hour,now.min,now.sec=0,0,0
  now.day=now.day-days+1
  local cutoff=os.time(now)
  local n,s,b,t=0,0,0,0
  for _,r in ipairs(history) do
    if r.at and r.at>=cutoff then local a,c,d=totals(r);n=n+1;s=s+a;b=b+c;t=t+d end
  end
  return n,s+b-t
end
local function summary(r)
  local salary,bonus,tax=totals(r)
  local t={'SHEWA PAYDAY '..(r.mult and ('X'..r.mult) or '(множитель не подтверждён)'), 'Время: '..r.time}
  table.insert(t,'Зарплата по сообщениям: $'..salary)
  if salary>0 and r.mult==1 then table.insert(t,'Зарплата без множителя: $'..salary)
  elseif salary>0 and r.mult and r.mult>1 and salary%r.mult==0 then
    table.insert(t,'Без множителя (оценка): $'..(salary/r.mult))
    table.insert(t,'Прибавка X'..r.mult..' (оценка): +$'..(salary-salary/r.mult))
  else table.insert(t,'Зарплата без множителя: не подтверждена') end
  table.insert(t,'Прочие бонусы: +$'..bonus)
  table.insert(t,'Налоги и списания: -$'..tax)
  table.insert(t,'Итого: $'..(salary+bonus-tax))
  table.insert(t,'Расчёт по игровым сообщениям, не подтверждённый баланс.')
  return table.concat(t,'\n')
end
local function urlenc(s) return (s:gsub('([^%w%-_%.~])',function(c) return ('%%%02X'):format(c:byte()) end)) end
local function send(text)
  if sending then return end
  if tostring(cfg.main.bot_token or '')=='' or tostring(cfg.main.chat_id or '')=='' then return end
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
    if ok then note('Telegram: отчёт доставлен') else note('Telegram: ошибка отправки. Проверьте настройки /pd') end
  end)
end
local function finish()
  if not active then return end
  local r=active; active=nil
  if #r.items==0 then diagnostic='Payday замечен, но подтверждённых сумм нет'; return end
  last=r
  table.insert(history,1,r)
  lastPaydayAt=r.at
  local salary,bonus,tax=totals(r)
  local ledger=io.open(historyPath,'a')
  if ledger then ledger:write(string.format('%d\t%d\t%d\t%d\t%d\n',r.at,r.mult or 0,salary,bonus,tax));ledger:close()
  else diagnostic='Не удалось сохранить историю на диск' end
  local f=io.open(getWorkingDirectory()..'/config/arizona_payday_pl_history.txt','a')
  if f then f:write('\n'..summary(r)..'\n');f:close() end
  if cfg.main.auto_send then send(summary(r)) end
  diagnostic='Payday записан: '..r.time
  note('Payday записан. Меню: /pd')
end
function ev.onServerMessage(color,text)
  local raw=clean(text)
  local ok,s=pcall(function() return u8:encode(raw) end)
  if not ok or type(s)~='string' then return end
  local l=lowerRu(s)
  if l:find('payday',1,true) or l:find('пейдей',1,true) or l:find('пэйдей',1,true) then
    if not active then
      active={at=os.time(),time=os.date('%Y-%m-%d %H:%M:%S'),mult=multiplier(s),items={},seen={}}
      lastAt=os.time()
      diagnostic='Payday обнаружен, собираю начисления'
    end
  end
  if not active then return end
  local m=multiplier(s)
  if m and (l:find('множител',1,true) or l:find('payday',1,true) or l:find('пейдей',1,true) or l:find('пэйдей',1,true) or l:find('зарплат',1,true)) then active.mult=m end
  local amount=num(s)
  local k=kind(s)
  if amount and amount > 0 and k and not active.seen[s] then
    active.seen[s]=true
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
  if id~='' and not id:match('^%-?%d+$') then note('Chat ID должен быть числом');return false end
  cfg.main.bot_token=tostring(token.v)
  cfg.main.chat_id=id
  cfg.main.auto_send=auto.v
  save()
  note('Настройки сохранены')
  return true
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
  return url==MANIFEST_URL or url==RELEASE_URL
end
local downloadSequence=0
local function fetch(url)
  if not trustedUrl(url) then error('Неизвестный источник обновлений') end
  local status=require('moonloader').download_status
  downloadSequence=downloadSequence+1
  local path=thisScript().path..'.download-'..os.time()..'-'..downloadSequence
  local complete,success,expired=false,false,false
  downloadUrlToFile(url,path,function(_,state)
    if state==status.STATUS_ENDDOWNLOADDATA then success=true end
    if state==status.STATUSEX_ENDDOWNLOAD then
      complete=true
      if expired then os.remove(path) end
    end
  end)
  local start=os.time()
  while not complete and os.time()-start<45 do wait(100) end
  if not complete then expired=true;error('Превышено время загрузки') end
  if not success then os.remove(path);error('Загрузка не удалась') end
  local f=io.open(path,'rb')
  if not f then error('Файл загрузки отсутствует') end
  local body=f:read(2*1024*1024+1) or ''
  f:close();os.remove(path)
  if #body>2*1024*1024 then error('Файл слишком большой') end
  return body
end
local function versionParts(s)
  local a,b,c=tostring(s):match('^(%d+)%.(%d+)%.(%d+)$')
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
      if not ver or not hash or #hash~=64 or download~=RELEASE_URL then error('Неверный manifest.txt') end
      if not versionParts(ver) then error('Неверная версия') end
      if versionParts(ver)>versionParts(VERSION) then
        updateInfo={version=ver,sha=hash:lower(),url=download}
        updateState='Доступна новая версия '..ver..'! Нажми УСТАНОВИТЬ.'
        if updateNoticeVersion~=ver then note('Update available: v'..ver..'. Open /pd'); updateNoticeVersion=ver end
      else updateInfo=nil;updateState='Установлена актуальная версия (GitHub: '..ver..')' end
    end)
    if not ok then updateInfo=nil;updateState='Ошибка проверки: '..tostring(err):sub(1,110) end
    updateBusy=false
  end)
end
local function installUpdate()
  if updateBusy or not updateInfo then return end
  if active or sending then updateState='Дождись завершения Payday или отправки отчёта';return end
  local info=updateInfo
  updateBusy=true;updateState='Скачиваю и проверяю SHA-256...'
  lua_thread.create(function()
    local ok,err=pcall(function()
      local data=fetch(info.url)
      if #data<100 or #data>2*1024*1024 then error('Неверный размер файла') end
      if not data:find("script_name('ARIZONA PAYDAY BOT PL')",1,true) then error('Неизвестный Lua-скрипт. Установка отменена') end
      if not data:find("script_version('"..info.version.."')",1,true) then error('Версия файла не совпадает') end
      local compiled,compileError=(loadstring or load)(data,'@payday-update')
      if not compiled then error('Ошибка синтаксиса обновления: '..tostring(compileError)) end
      local path=thisScript().path
      local tmp=path..'.new'
      if tmp:find('[%%!&|<>^"\r\n]') then error('Недопустимый путь к скрипту') end
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
      if active or sending then os.remove(tmp);error('Подожди завершения текущего отчёта') end
      local backup=path..'.bak-'..os.time()
      if not os.rename(path,backup) then error('Не удалось создать резервную копию') end
      if not os.rename(tmp,path) then os.rename(backup,path);error('Не удалось заменить скрипт') end
      updateInfo=nil
      updateState='Версия '..info.version..' установлена. Перезагрузка скрипта...'
      reloadPending=true
    end)
    if not ok then updateState='Ошибка установки: '..tostring(err):sub(1,110) end
    note(ok and 'Обновление установлено. Перезагружаю скрипт.' or 'Ошибка установки. Подробности в /pd')
    updateBusy=false
  end)
end


function imgui.OnDrawFrame()
  if not window.v then return end
  imgui.SetNextWindowSize(imgui.ImVec2(640, 590), imgui.Cond.FirstUseEver)
  if imgui.SetNextWindowBgAlpha then imgui.SetNextWindowBgAlpha(1.0) end
  imgui.Begin('ARIZONA  |  PAYDAY BOT  |  /pd', window)
  if imgui.GetWindowDrawList and imgui.GetWindowPos and imgui.GetWindowSize then
    -- Existing ImGui theme remains opaque; no transparent decorative image overlay.
  end
  animatedLine()
  accent('A R I Z O N A    /    P A Y D A Y')
  imgui.TextDisabled('SHEWA PAYDAY  /  v'..VERSION)
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
    if saveForm() then send('SHEWA PAYDAY: проверка подключения') end
  end
  imgui.Separator()
  accent('02   PAYDAY / ОТЧЁТ')
  local r=active or last
  if r then
    local salary,bonus,tax=totals(r)
    imgui.Text('Множитель: '..(r.mult and ('X'..r.mult) or 'не определён')..'   |   '..r.time)
    imgui.Text('Зарплата: $'..salary..'   Бонус: +$'..bonus..'   Налоги: -$'..tax)
    imgui.Text('Итого по сообщениям: $'..(salary+bonus-tax))
    if (r.saved or #r.items > 0) and imgui.Button('ОТПРАВИТЬ ОТЧЁТ', imgui.ImVec2(190, 32)) then if saveForm() then send(summary(r)) end end
  else
    imgui.TextDisabled('Ожидаем Payday. Множитель определяется автоматически.')
  end
  imgui.TextWrapped(diagnostic)
  imgui.TextDisabled('Всего записано: '..#history)
  for _,period in ipairs({{1,'Сегодня'},{7,'7 дней'},{30,'30 дней'}}) do
    local count,net=stats(period[1])
    imgui.Text(period[2]..': '..count..' выплат | $'..net)
  end
  if lastPaydayAt then
    local remaining=3600-(os.time()-lastPaydayAt)
    if remaining>0 then imgui.Text(string.format('До следующего Payday (оценка): %02d:%02d',math.floor(remaining/60),remaining%60))
    else imgui.TextDisabled('Ожидаем следующий Payday') end
  end
  if imgui.CollapsingHeader('История выплат') then
    for i=1,math.min(#history,30) do local item=history[i];local a,b,c=totals(item);imgui.Text(item.time..' | $'..(a+b-c)) end
  end
  imgui.Separator()
  accent('03   ОБНОВЛЕНИЯ')
  imgui.TextWrapped(updateState)
  imgui.TextDisabled('Автопроверка каждые 20 секунд. Установка в игре.')
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
  loadHistory()
  local function toggleWindow()
    window.v=not window.v
    imgui.Process=window.v
    imgui.ShowCursor=window.v
    imgui.LockPlayer=window.v
  end
  sampRegisterChatCommand('pd',toggleWindow)
  if not sampIsChatCommandDefined or not sampIsChatCommandDefined('pl') then sampRegisterChatCommand('pl',toggleWindow) end
  local filled, fillErr = pcall(fill)
  if not filled then print('[PAYDAY PL] Config field error: '..tostring(fillErr)) end
  local themed, themeErr = pcall(theme)
  if not themed then print('[PAYDAY PL] Theme fallback: '..tostring(themeErr)) end
  note('Готово. Меню: /pd')
  checkUpdate()
  while true do
    wait(100)
    if reloadPending then
      window.v=false
      imgui.Process=false
      imgui.ShowCursor=false
      imgui.LockPlayer=false
      wait(300)
      thisScript():reload()
      return
    end
    imgui.Process=window.v
    imgui.ShowCursor=window.v
    imgui.LockPlayer=window.v
    if not updateBusy and os.time()-lastUpdateCheck>=UPDATE_INTERVAL then checkUpdate() end
    if active and (os.time()-lastAt >= (tonumber(cfg.main.settle_seconds) or 15) or os.time()-active.at>=60) then finish() end
  end
end
