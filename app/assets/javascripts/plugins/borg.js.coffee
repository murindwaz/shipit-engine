filterAshburn = (text) ->
  String(text).replace(/^.*\[ash\].*$/gm, '').replace(/^.*\.ash\.shopify\.com.*$/gm, '').replace(/\[chi\]/mg,'')
    
# Abstract, need to implement @refresh and @parse
class BaseTaskWidget
  constructor: ->
    @active = false

  addHeading: ->
    @$headingEl = $("<h2 class='task-group-heading'></h2>")
    @$headingEl.appendTo(@$container)

  newContainer: ->
    if @$container
      @$container.empty()
    else
      @$container = Sidebar.newWidgetContainer()
    @addHeading()
    @$container.append("<div class='section-bottom'></div>")

  activate: ->
    return if @active
    @newContainer()
    @$headingEl.text(@heading)
    @active = true

  finish: ->
    return unless @active
    @$headingEl.text(@heading + " \u2713") # add check mark
    @active = false
    @tasks = {}

  update: (text) ->
    parser = new CapistranoParser(filterAshburn(text))
    @parse(parser)
    @refresh()
    null

# Abstract, need to implement @parse
class RestartTaskWidget extends BaseTaskWidget
  constructor: ->
    super
    @tasks = {}

  createTask: (host) ->
    new LightsTaskView(@$container, host)

  getTask: (host) ->
    @activate()
    @tasks[host] ||= @createTask(host)

  refresh: ->
    for _, task of @tasks
      task.updateDOM()
    null

# Abstract, need to implement @parse
class ProgressBarTaskWidget extends BaseTaskWidget
  constructor: ->
    super
    @total = 1
    @done = 0

  newContainer: ->
    super
    @$bar = $("<div>").addClass("task-progress-container")
    @$donePart = $("<div>").addClass("task-progress-bar").appendTo(@$bar)
    @$bar.insertBefore(@$container.find('.section-bottom'))

  refresh: ->
    return unless @active
    frac = @done / @total
    doneWidth = @$bar.width() * frac
    @$donePart.width(doneWidth)

class AssetsUploadWidget extends ProgressBarTaskWidget
  constructor: ->
    super
    @heading = "Uploading Assets"
    @capistranoTask = "assets:upload"

  update: (text) ->
    parser = new CapistranoParser(filterAshburn(text))
    @parse(parser)
    @refresh()
    null

  parse: (parser) ->
    parser.eachMessage (log) =>
      if match = log.output.match(/S3 assets uploading \[(\d+)\/(\d+)\]/)
        @done = +(match[1])
        @total = +(match[2])
    null

class ContainersRestartWidget extends RestartTaskWidget
  constructor: ->
    super
    @heading = "Restarting Servers"

  parse: (parser) ->
    parser.eachMessage (log) =>
      if match = log.output.match(/\[(\d+)\/(\d+)\].* restarting/i)
        @getTask(log.host).update
          numPending: match[1]
          numLights: match[2]
      else if match = log.output.match(/\[(\d+)\/(\d+)\].* (successfully restarted|was not required to restart in time)/i)
        @getTask(log.host).update
          numDone: match[1]
          numLights: match[2]
      else if match = log.output.match(/\[(\d+)\/(\d+)\].* did not restart in time/i)
        @getTask(log.host).update(numPending: match[1], numLights: match[2]).fail()
      else if match = log.output.match(/\[(\d+)\/(\d+)\].* (failed to restart|unable to restart)/i)
        @getTask(log.host).update(numPending: match[1], numLights: match[2]).fail()
    null

class LightsTaskView
  TEMPLATE = $.trim """
    <div class="task-lights">
      <span class="task-lights-text">
        <span class="task-lights-title"></span>
      </span>
      <span class="task-lights-boxes"></span>
    </div>
  """
  numLights: 0
  numPending: 0
  numDone: 0

  constructor: (@$container, host) ->
    @$element = $(TEMPLATE)
    @$title = host.split('.')[0]
    @$element.find('.task-lights-title').text(@$title)
    @insertSorted(@$element, @$title)

  insertSorted: (toInsert, title) ->
    inserted = false
    @$container.find('.task-lights').each ->
      title2 = $('.task-lights-title',this).text()
      # Sort shorter names first, so that the sort ends up 
      # like [sb1,sb2,sb10] not [sb1,sb10,sb2]
      if title2.length > title.length || (title2 > title && title2.length == title.length)
        toInsert.insertBefore(this)
        inserted = true
        return false
    toInsert.insertBefore(@$container.find('.section-bottom')) unless inserted

  genBoxes: ->
    boxes = document.createDocumentFragment();
    for i in [1..(+@numLights)]
      status = if i <= @numDone
        'up'
      else if i <= @numPending
        'partial'
      else
        'neutral'
      $('<span>').addClass("task-lights-box box-#{status}").appendTo(boxes)
    boxes

  update: (attrs) ->
    $.extend(this, attrs)
    this

  updateDOM: ->
    @$element.find('.task-lights-boxes').empty().append(@genBoxes())
    this

  fail: ->
    @$element.addClass('task-failed')

BORG_WIDGETS = [AssetsUploadWidget, ContainersRestartWidget]
borgWidgetInstances = for widget in BORG_WIDGETS
  new widget()

ChunkPoller.prependFormatter (chunk) ->
  for widget in borgWidgetInstances
    widget.update(ChunkPoller.stripANSICodes(chunk))
  false
