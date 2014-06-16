class NFinderController extends KDViewController

  constructor:(options = {}, data)->

    options.view = new KDView cssClass : "nfinder file-container"

    treeOptions  = {}
    treeOptions.treeItemClass     = options.treeItemClass     or= NFinderItem
    treeOptions.nodeIdPath        = options.nodeIdPath        or= "path"
    treeOptions.nodeParentIdPath  = options.nodeParentIdPath  or= "parentPath"
    treeOptions.dragdrop          = options.dragdrop           ?= yes
    treeOptions.foldersOnly       = options.foldersOnly        ?= no
    treeOptions.hideDotFiles      = options.hideDotFiles       ?= no
    treeOptions.multipleSelection = options.multipleSelection  ?= yes
    treeOptions.addOrphansToRoot  = options.addOrphansToRoot   ?= no
    treeOptions.putDepthInfo      = options.putDepthInfo       ?= yes
    treeOptions.contextMenu       = options.contextMenu        ?= yes
    treeOptions.maxRecentFolders  = options.maxRecentFolders  or= 10
    treeOptions.useStorage        = options.useStorage         ?= no
    treeOptions.loadFilesOnInit   = options.loadFilesOnInit    ?= no
    treeOptions.delegate          = this

    super options, data


    TreeControllerClass = options.treeControllerClass or NFinderTreeController
    @treeController     = new TreeControllerClass treeOptions, []

    {appStorageController} = KD.singletons
    @appStorage = appStorageController.storage 'Finder', '2.0'

    @watchers = {}

    # this is here for when user login/register after opening Ace App
    # to refresh filetree
    mainController = KD.getSingleton("mainController")
    mainController.on "accountChanged.to.loggedIn", @bound 'reset'

    if options.useStorage
      @appStorage.ready =>
        @treeController.on "file.opened", @bound 'setRecentFile'
        @treeController.on "folder.expanded", (folder)=>
          @setRecentFolder folder.path
        @treeController.on "folder.collapsed", ({path})=>
          @unsetRecentFolder path
          @stopWatching path

    @cleanup()

    vmc = KD.getSingleton("vmController")
    vmc.on "StateChanged", @bound "checkVMState"
    vmc.on "VMDestroyed",  @bound "unmountVm"

  registerWatcher:(path, stopWatching)->
    @watchers[path] = stop: stopWatching
    @noMachineFoundWidget = new NoMachinesFoundWidget

  stopAllWatchers:->
    (watcher.stop() for own path, watcher of @watchers)
    @watchers = {}

  stopWatching:(pathToStop)->
    for own path, watcher of @watchers  when (path.indexOf pathToStop) is 0
      watcher.stop()
      delete @watchers[path]

  loadView:(mainView)->
    mainView.addSubView @treeController.getView()
    @viewLoaded = yes
    mainView.addSubView @noMachineFoundWidget

    @reset()  if @getOptions().loadFilesOnInit

  reset:->
    KD.singletons.vmController.ready =>
      if @getOptions().useStorage
        @appStorage.ready => @loadVms()
      else
        @utils.defer => @loadVms()

  parseSavedVms = (vms) ->
    vms.reduce (memo, str) ->
      [vmName, path] = str.split ':'
      memo[0].push vmName
      memo[1].push path
      memo
    , [[],[]]

  fetchSavedVms: (savedVms, callback) ->
    [vmNames, paths] = parseSavedVms savedVms

    KD.getSingleton('vmController').fetchVmsByName vmNames, (err, vms) =>
      return callback? err  if err

      vms[i].path = paths[i]  for _, i in vms
  loadMachines:->

      callback null, vms
    { computeController } = KD.singletons

  getVmNode:(vmName)->
    return null  unless vmName
    for own path, vmItem of @treeController.nodes  when vmItem.data?.type is 'vm'
      return vmItem  if vmItem.data.vmName is vmName
    computeController.fetchMachines (err, machines)=>

      unless KD.showError err
        if machines.length > 0
        then @mountMachines machines
        else @noMachineFoundWidget.show()


  updateMountState:(vmName, state)->
    return  if KD.isGuest()
    groupSlug  = KD.getSingleton("groupsController").getGroupSlug()
    groupSlug ?= KD.defaultSlug
    vms = @appStorage.getValue("mountedVM") or {}
    vms[groupSlug] or= []
    items = vms[groupSlug]
    if state and vmName not in items
      items.push vmName
    else if not state and vmName in items
      items.splice items.indexOf(vmName), 1
    @appStorage.setValue "mountedVM", vms

  checkVMState: (err, vm, info)->
    return warn err if err or not info
    switch info.state
      when "MAINTENANCE" then @unmountVm vm
  mountMachine:(machine, fetchContent = yes)->

    unless machine.status.state is Machine.State.Running
      return warn "Machine '#{machine.getName()}' was not ready, I skipped it."

    { uid } = machine
    mRoots  = (@appStorage.getValue 'machineRoots') or {}
    path    = mRoots[uid] or "/"

    if @getMachineNode uid
      return warn "Machine #{machine.getName()} is already mounted!"

    @updateMountState uid, yes

    @machines.push FSHelper.createFileInstance
      name           : path
      path           : "[#{uid}]#{path}"
      type           : "machine"
      machine        : machine
      treeController : @treeController

    @noMachineFoundWidget.hide()

    machineItem = @treeController.addNode @machines.last

    if fetchContent and machineItem

      @utils.defer =>

        @treeController.expandFolder machineItem, (err)=>

          @treeController.selectNode machineItem

          @utils.defer =>
            if @getOptions().useStorage then @reloadPreviousState uid
        , yes

  unmountVm:(vmName)->
    vmItem = @getVmNode vmName
    return warn 'No such VM!'  unless vmItem

    @updateMountState vmName, no
    @stopWatching vmItem.data.path
    FSHelper.unregisterVmFiles vmName
    @treeController.removeNodeView vmItem
    @vms = @vms.filter (vmData)-> vmData isnt vmItem.data
  mountMachines: (machines) ->

    do @cleanup
    for machine in machines
      @mountMachine machine


    if @machines.length is 0
      @noMachineFoundWidget.show()
      @emit 'EnvironmentsTabRequested'

  updateVMRoot:(vmName, path, callback)->
    return warn 'VM name and new path required!'  unless vmName or path

    @unmountVm vmName
    callback?()

    vmRoots = (@appStorage.getValue 'vmRoots') or {}
    pipedVm = @_pipedVmName vmName
    vmRoots[pipedVm] = path
    @appStorage.setValue 'vmRoots', vmRoots  if @getOptions().useStorage

    KD.singleton("vmController").fetchVmsByName [vmName], (err, [vm]) =>
      return KD.showError err  if err
      vm.path = path
      @mountVm vm

  cleanup:->
    @treeController.removeAllNodes()
    FSHelper.resetRegistry()
    @stopAllWatchers()
    @vms = []

  setRecentFile:({path})->
    recentFiles = @appStorage.getValue('recentFiles')
    recentFiles = []  unless Array.isArray recentFiles

    unless path in recentFiles
      if recentFiles.length is @treeController.getOptions().maxRecentFiles
        recentFiles.pop()
      recentFiles.unshift path

    @appStorage.setValue 'recentFiles', recentFiles.slice(0,10), =>
      @emit 'recentfiles.updated', recentFiles

  hideDotFiles:(vmName)->
    return  unless vmName
    @setNodesHidden vmName, yes
    for own path, node of @treeController.nodes
      file = node.getData()
      if (file.vmName is vmName) and file.isHidden()
        @stopWatching file.path
        @treeController.removeNodeView node

  showDotFiles:(vmName)->
    return  unless vmName
    @setNodesHidden vmName, no
    for own path, node of @treeController.nodes when node.getData().type is 'vm'
      return if node.getData().vmName is vmName
        @treeController.collapseFolder node, =>
          @reloadPreviousState vmName
        , yes

  isNodesHiddenFor:(vmName)->
    return yes  if @getOption 'hideDotFiles'
    pipedVm = @_pipedVmName vmName
    return (@appStorage.getValue('vmsDotFileChoices') or {})[pipedVm]

  setNodesHidden:(vmName, state)->
    pipedVm = @_pipedVmName vmName
    prefs   = @appStorage.getValue('vmsDotFileChoices') or {}
    prefs[pipedVm] = state
    @appStorage.setValue 'vmsDotFileChoices', prefs

  getRecentFolders:->
    recentFolders = @appStorage.getValue('recentFolders')
    recentFolders = []  unless Array.isArray recentFolders
    return recentFolders

  setRecentFolder:(folderPath, callback)->
    recentFolders = @getRecentFolders()
    unless folderPath in recentFolders
      recentFolders.push folderPath
    recentFolders.sort (path)-> if path is folderPath then -1 else 0
    @appStorage.setValue 'recentFolders', recentFolders, callback

  unsetRecentFolder:(folderPath, callback)->
    recentFolders = @getRecentFolders()
    recentFolders = recentFolders.filter (path)->
      path.indexOf(folderPath) isnt 0
    recentFolders.sort (path)->
      if path is folderPath then -1 else 0
    @appStorage.setValue 'recentFolders', recentFolders, callback

  expandFolder:(folderPath, callback=noop)->
    return  unless folderPath
    for own path, node of @treeController.nodes
      return @treeController.expandFolder node, callback  if path is folderPath
    callback {message:"Folder not exists: #{folderPath}"}

  expandFolders: (paths, callback=noop)->
    if typeof paths is 'string'
      paths = FSHelper.getPathHierarchy paths
    path = paths.pop()
    @expandFolder path, (err)=>
      @unsetRecentFolder path  if err
      if paths.length is 0
      then callback null, @treeController.nodes[path]
      else @expandFolders paths, callback

  reloadPreviousState:(vmName)->
    recentFolders = @getRecentFolders()
    if vmName
      recentFolders = recentFolders.filter (folder)->
        folder.indexOf "[#{vmName}]" is 0
      if recentFolders.length is 0
        recentFolders = ["[#{vmName}]/home/#{KD.nick()}"]
    @expandFolders recentFolders

  uploadTo: (path)->
    {uploader, uploaderPlaceholder} = @getDelegate()
    uploader.setPath path
    uploaderPlaceholder.show()

  _pipedVmName:(vmName)-> vmName.replace /\./g, '|'

