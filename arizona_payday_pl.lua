script_name('ARIZONA PAYDAY BOT PL')
script_author('SHEWA')
script_version('1.3.0')

local inicfg = require 'inicfg'
local encoding = require 'encoding'
local ev = require 'samp.events'
local imgui = require 'imgui' -- MoonLoader legacy ImGui
encoding.default = 'CP1251'
local u8 = encoding.UTF8
local configName = 'arizona_payday_pl'
local MANIFEST_URL = 'https://raw.githubusercontent.com/xromxgame-lgtm/ARIZONA-PAYDAY-BOT/main/manifest.txt'
local updateState = 'Проверка не выполнена'
local updateInfo, updateBusy = nil, false
local cfg = inicfg.load({main={bot_token='',chat_id='',multiplier=1,auto_send=true,settle_seconds=15}},configName)
local window = imgui.ImBool(false)
local token = imgui.ImBuffer(256)
local chatid = imgui.ImBuffer(64)
local auto = imgui.ImBool(cfg.main.auto_send)
local selected = imgui.ImInt(tonumber(cfg.main.multiplier) or 1)
local active,last,lastAt = nil,nil,0
local history = {}
local sending = false

imgui.OnInitialize = function()
  local io = imgui.GetIO()
  local font = getFolderPath(0x14)..'\\arial.ttf'
  if doesFileExist(font) then
    io.Fonts:Clear()
    io.Fonts:AddFontFromFileTTF(font, 16, nil, io.Fonts:GetGlyphRangesCyrillic())
  end
end
local function save() inicfg.save(cfg,configName) end
local function note(s) sampAddChatMessage('[PAYDAY PL] '..s,0x65CFFF) end
local function clean(s) return (s or ''):gsub('{%x%x%x%x%x%x}',''):gsub('~[%a]~','') end
local function num(s)
  local a=s:match('%$%s*([%d%s%,%.]+)') or s:match('([%d][%d%s%,%.]*)%s*%$')
  return a and tonumber((a:gsub('[^%d]',''))) or nil
end
local function multiplier(s)
  local n=s:lower():match('[xх]%s*([1234])') or s:lower():match('([1234])%s*[xх]')
  return tonumber(n)
end
local function kind(s)
  local l=s:lower()
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
local function summary(r)
  local salary,bonus,tax=totals(r)
  local t={'ARIZONA PAYDAY x'..r.mult, 'Time: '..r.time}
  table.insert(t,'Salary reported by server: $'..salary)
  if salary>0 and r.mult==1 then table.insert(t,'Salary without x: $'..salary)
  elseif salary>0 and r.mult>1 and salary%r.mult==0 then
    table.insert(t,'Base salary (ESTIMATE): $'..(salary/r.mult))
    table.insert(t,'x'..r.mult..' difference (ESTIMATE): +$'..(salary-salary/r.mult))
  else table.insert(t,'Base salary: not verified') end
  table.insert(t,'Other bonuses: +$'..bonus)
  table.insert(t,'Taxes and charges: -$'..tax)
  table.insert(t,'Calculated net: $'..(salary+bonus-tax))
  table.insert(t,'--- Game messages ---')
  for _,v in ipairs(r.items) do table.insert(t,(v.kind=='tax' and '- ' or '+ ')..v.text) end
  table.insert(t,'Based on detected chat messages; not a verified account balance.')
  return table.concat(t,'\n')
end
local function urlenc(s) return (s:gsub('([^%w%-_%.~])',function(c) return ('%%%02X'):format(c:byte()) end)) end
local function send(text)
  if sending then note('Sending in progress');return end
  if cfg.main.bot_token=='' or cfg.main.chat_id=='' then note('Configure Telegram in /pl');return end
  sending=true
  lua_thread.create(function()
    local ok,err=pcall(function()
      local https=require 'ssl.https'
      local ltn12=require 'ltn12'
      local payload='chat_id='..urlenc(cfg.main.chat_id)..'&text='..urlenc(text)
      local chunks={}
      local _,status=https.request({url='https://api.telegram.org/bot'..cfg.main.bot_token..'/sendMessage',method='POST',headers={['content-type']='application/x-www-form-urlencoded',['content-length']=tostring(#payload)},source=ltn12.source.string(payload),sink=ltn12.sink.table(chunks)})
      if tonumber(status)~=200 then error('Telegram HTTP '..tostring(status)) end
      if not table.concat(chunks):find('"ok"%s*:%s*true') then error('Telegram API rejected message') end
    end)
    sending=false
    if ok then note('Telegram message sent') else note('Telegram error (check token, chat ID, HTTPS libraries)') end
  end)
end
local function finish()
  if not active then return end
  local r=active; active=nil
  if #r.items==0 then return end
  last=r
  table.insert(history,1,r)
  if #history>20 then table.remove(history) end
  local f=io.open(getWorkingDirectory()..'/config/arizona_payday_pl_history.txt','a')
  if f then f:write('\n'..summary(r)..'\n');f:close() end
  if cfg.main.auto_send then send(summary(r)) end
  note('Payday x'..r.mult..' captured. /pl for details')
end
function ev.onServerMessage(color,text)
  local s=u8:encode(clean(text))
  local l=s:lower()
  if l:find('payday',1,true) or l:find('пейдей',1,true) or l:find('пэйдей',1,true) then
    finish()
    active={time=os.date('%Y-%m-%d %H:%M:%S'),mult=multiplier(s) or tonumber(cfg.main.multiplier) or 1,items={}}
    lastAt=os.clock()
    return
  end
  if not active then return end
  local m=multiplier(s)
  if m and l:find('множител',1,true) then active.mult=m end
  local amount=num(s)
  local k=kind(s)
  if amount and k then
    table.insert(active.items,{kind=k,amount=amount,text=s})
    lastAt=os.clock()
  end
end
local function fill()
  token.v=cfg.main.bot_token
  chatid.v=cfg.main.chat_id
  auto.v=cfg.main.auto_send
  selected.v=tonumber(cfg.main.multiplier) or 1
end
local function saveForm()
  local id=tostring(chatid.v)
  if id~='' and not id:match('^%-?%d+$') then note('Chat ID must be a number');return end
  cfg.main.bot_token=tostring(token.v)
  cfg.main.chat_id=id
  cfg.main.auto_send=auto.v
  cfg.main.multiplier=math.max(1,math.min(4,selected.v))
  save()
  note('Settings saved')
end
function imgui.OnInitialize()
  local io = imgui.GetIO()
  local path = getFolderPath(0x14) .. [[\arial.ttf]]
  if doesFileExist(path) then
    io.Fonts:AddFontFromFileTTF(path, 16, nil, io.Fonts:GetGlyphRangesCyrillic())
  end
end

local function trustedUrl(url)
  if type(url)~='string' then return false end
  local host=url:match('^https://([^/]+)/')
  return host=='raw.githubusercontent.com' or host=='github.com'
end
local function fetch(url)
  if not trustedUrl(url) then error('Разрешены только HTTPS-ссылки GitHub') end
  local https=require 'ssl.https'
  local ltn12=require 'ltn12'
  local chunks={}
  local _,status=https.request({url=url,sink=ltn12.sink.table(chunks)})
  if tonumber(status)~=200 then error('HTTP '..tostring(status)) end
  return table.concat(chunks)
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
  updateBusy=true; updateState='Проверяю обновления...'
  lua_thread.create(function()
    local ok,err=pcall(function()
      local body=fetch(url)
      local ver,hash,download=body:match('^%s*([^|\r\n]+)|([a-fA-F0-9]+)|([^\r\n]+)')
      if not ver or not hash or #hash~=64 or not trustedUrl(download) then error('Неверный manifest.txt') end
      if not versionParts(ver) then error('Неверная версия') end
      if versionParts(ver)>versionParts('1.3.0') then
        updateInfo={version=ver,sha=hash:lower(),url=download}
        updateState='Доступна новая версия '..ver
      else updateInfo=nil;updateState='Новых версий нет' end
    end)
    if not ok then updateInfo=nil;updateState='Ошибка проверки: '..tostring(err):sub(1,110) end
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
    updateBusy=false
  end)
end


function imgui.OnDrawFrame()
  if not window.v then return end
  imgui.SetNextWindowSize(imgui.ImVec2(560,490),imgui.Cond.FirstUseEver)
  imgui.Begin('ARIZONA PAYDAY BOT | /pl',window)
  imgui.Text('НАСТРОЙКА TELEGRAM')
  imgui.Separator()
  imgui.Text('Токен Telegram-бота')
  imgui.InputText('##token',token,imgui.InputTextFlags.Password)
  imgui.Text('Tелеграм Chat ID')
  imgui.InputText('##chat',chatid)
  imgui.Checkbox('Автоматически отправлять Payday',auto)
  imgui.Text('Множитель по умолчанию (если сервер не сообщил)')
  imgui.RadioButton('X1',selected,1);imgui.SameLine()
  imgui.RadioButton('X2',selected,2);imgui.SameLine()
  imgui.RadioButton('X3',selected,3);imgui.SameLine()
  imgui.RadioButton('X4',selected,4)
  if imgui.Button('Сохранить',imgui.ImVec2(140,30)) then saveForm() end
  imgui.SameLine()
  if imgui.Button('Проверить Telegram',imgui.ImVec2(180,30)) then
    saveForm()
    send('ARIZONA PAYDAY BOT: test connection')
  end
  imgui.Separator()
  imgui.Text('ПОСЛЕДНИЙ PAYDAY')
  local r=active or last
  if r then
    local s,b,t=totals(r)
    imgui.Text('Payday x'..r.mult..' | '..r.time)
    imgui.Text('Salary: $'..s..' | Bonus: +$'..b..' | Taxes: -$'..t)
    imgui.Text('Net (detected): $'..(s+b-t))
    if imgui.Button('Отправить отчёт сейчас') then saveForm();send(summary(r)) end
  else imgui.Text('Данных пока нет. Дождись Payday в игре.') end
  imgui.Text('История: '..#history..' Payday за текущий запуск')
  imgui.Separator()
  imgui.Text('ОБНОВЛЕНИЯ | версия 1.3.0')
  imgui.TextWrapped(updateState)
  if imgui.Button('Проверить обновления') then checkUpdate() end
  if updateInfo then
    imgui.SameLine()
    if imgui.Button('Установить обновление') then installUpdate() end
  end
  imgui.End()
end
function main()
  while not isSampAvailable() do wait(200) end
  fill()
  sampRegisterChatCommand('pl',function() window.v=not window.v;imgui.Process=window.v end)
  note('Loaded. Type /pl to open Telegram settings.')
  checkUpdate()
  while true do
    wait(100)
    imgui.Process=window.v
    if active and #active.items>0 and os.clock()-lastAt >= tonumber(cfg.main.settle_seconds) then finish() end
  end
end