OmegaTargetCurrent = Object.create(OmegaTargetChromium)
Promise = OmegaTargetCurrent.Promise
Promise.longStackTraces()

OmegaTargetCurrent.Log = Object.create(OmegaTargetCurrent.Log)
Log = OmegaTargetCurrent.Log
Log.log = (args...) ->
  console.log(args...)
  localStorage['log'] += args.map(Log.str.bind(Log)).join(' ') + '\n'
Log.error = (args...) ->
  console.error(args...)
  content = args.map(Log.str.bind(Log)).join(' ')
  localStorage['log'] += 'ERROR: ' + content + '\n'

unhandledPromises = []
unhandledPromisesId = []
unhandledPromisesNextId = 1
Promise.onPossiblyUnhandledRejection (reason, promise) ->
  Log.error("[#{unhandledPromisesNextId}] Unhandled rejection:\n", reason)
  unhandledPromises.push(promise)
  unhandledPromisesId.push(unhandledPromisesNextId)
  unhandledPromisesNextId++
Promise.onUnhandledRejectionHandled (promise) ->
  index = unhandledPromises.indexOf(promise)
  Log.log("[#{unhandledPromisesId[index]}] Rejection handled!", promise)
  unhandledPromises.splice(index, 1)
  unhandledPromisesId.splice(index, 1)

iconCache = {}
drawIcon = (resultColor, profileColor) ->
  cacheKey = "omega+#{resultColor ? ''}+#{profileColor}"
  icon = iconCache[cacheKey]
  return icon if icon
  ctx = document.getElementById('canvas-icon').getContext('2d')
  if resultColor?
    drawOmega ctx, resultColor, profileColor
  else
    drawOmega ctx, profileColor
  icon = ctx.getImageData(0, 0, 19, 19)
  return iconCache[cacheKey] = icon

charCodeUnderscore = '_'.charCodeAt(0)
isHidden = (name) -> (name.charCodeAt(0) == charCodeUnderscore and
  name.charCodeAt(1) == charCodeUnderscore)

dispName = (name) -> chrome.i18n.getMessage('profile_' + name) || name

actionForUrl = (url) ->
  options.ready.then(->
    request = OmegaPac.Conditions.requestFromUrl(url)
    options.matchProfile(request)
  ).then ({profile, results}) ->
    current = options.currentProfile()
    details = ''
    direct = false
    attached = false
    for result in results
      if Array.isArray(result)
        if not result[1]?
          attached = false
          name = result[0]
          if name[0] == '+'
            name = name.substr(1)
          if isHidden(name)
            attached = true
          else
            details += chrome.i18n.getMessage 'browserAction_defaultRuleDetails'
            details += " => #{dispName(name)}\n"
        else if result[1].length == 0
          if result[0] == 'DIRECT'
            details += chrome.i18n.getMessage('browserAction_directResult')
            details += '\n'
          else
            details += "#{result[0]}\n"
        else if typeof result[1] == 'string'
          details += "#{result[1]} => #{result[0]}\n"
        else
          condition = (result[1].condition ? result[1]).pattern ? ''
          details += "#{condition} => "
          if result[0] == 'DIRECT'
            details += chrome.i18n.getMessage('browserAction_directResult')
            details += '\n'
            direct = true
          else
            details += "#{result[0]}\n"
      else if result.profileName
        if result.isTempRule
          details += chrome.i18n.getMessage('browserAction_tempRulePrefix')
        else if attached
          details += chrome.i18n.getMessage('browserAction_attachedPrefix')
          attached = false
        condition = (result.source ? result.condition.pattern ?
          result.condition.conditionType)
        details += "#{condition} => #{dispName(result.profileName)}\n"

    icon =
      if profile.name == current.name and options.isCurrentProfileStatic()
        if direct
          drawIcon(options.profile('direct').color, profile.color)
        else
          drawIcon(profile.color)
      else
        drawIcon(profile.color, current.color)
    return {
      title: chrome.i18n.getMessage('browserAction_titleWithResult', [
        dispName(current.name)
        dispName(profile.name)
        details
      ])
      icon: icon
    }


storage = new OmegaTargetCurrent.Storage(chrome.storage.local, 'local')
state = new OmegaTargetCurrent.BrowserStorage(localStorage, 'omega.local.')
options = new OmegaTargetCurrent.Options(null, storage, state, Log)

tabs = new OmegaTargetCurrent.ChromeTabs(actionForUrl)
tabs.watch()

options.setProxyNotControllable(null)
timeout = null

options.watchProxyChange (details) ->
  lastProxyChangeAt = Date.now()
  switch details['levelOfControl']
    when "controllable_by_this_extension"
      break
    when "controlled_by_other_extensions", "not_controllable"
      reason =
        if details['levelOfControl'] == 'not_controllable'
          'policy'
        else
          'app'
      options.setProxyNotControllable(reason)
    else
      options.setProxyNotControllable(null)

  return if details['levelOfControl'] == 'controlled_by_this_extension'
  Log.log('external proxy: ', details)

  # Chromium will send chrome.proxy.settings.onChange on extension unload,
  # just after the current extension has lost control of the proxy settings.
  # This is just annoying, and may change the currentProfileName state
  # suprisingly.
  # To workaround this issue, wait for some time before setting the proxy.
  # However this will cause some delay before the settings are processed.
  clearTimeout(timeout) if timeout?
  timeout = setTimeout (->
    options.setExternalProfile(
      options.parseExternalProfile(details),
      noRevert: true)
  ), 500
  return

external = false
options.currentProfileChanged = (reason) ->
  profile = options.currentProfile()
  iconCache = {}

  if reason == 'external'
    external = true
  else if reason != 'clearBadge'
    external = false

  title =
    if profile.name == ''
      details = profile.pacUrl ? options.printFixedProfile(profile)
      details = details ? profile.profileType
    else
      chrome.i18n.getMessage('browserAction_titleNormal', [
        options._currentProfileName
      ])
  if external and profile.profileType != 'SystemProfile'
    message = chrome.i18n.getMessage('browserAction_titleExternalProxy')
    title = message + '\n' + title
    options.setBadge()

  tabs.resetAll(
    icon: drawIcon(profile.color)
    title: title
  )

encodeError = (obj) ->
  if obj instanceof Error
    {
      _error: 'error'
      name: obj.name
      message: obj.message
      stack: obj.stack
      original: obj
    }
  else
    obj

chrome.runtime.onMessage.addListener (request, sender, respond) ->
  options.ready.then ->
    target = options
    method = target[request.method]
    if typeof method != 'function'
      Log.error("No such method #{request.method}!")
      respond(
        error:
          reason: 'noSuchMethod'
      )
      return

    promise = Promise.resolve().then -> method.apply(target, request.args)

    promise.then (result) ->
      if request.method == 'updateProfile'
        for own key, value of result
          result[key] = encodeError(value)
      respond(result: result)

    promise.catch (error) ->
      Log.error(request.method + ' ==>', error)
      respond(error: encodeError(error))

  # Wait for my response!
  return true
