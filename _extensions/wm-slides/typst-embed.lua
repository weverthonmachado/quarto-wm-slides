--[[
typst-embeds – compile typst-embed code blocks into SVG images.

Options are specified as  //| key: value  lines at the top of the block.
This uses Typst's native line-comment syntax so it doesn't interfere with
Typst's own parser.  Supported options:

  //| fig-cap: My caption  → wraps output in a pandoc Figure
  //| width: 80%           → passed as an HTML/CSS width attribute
  //| height: 400px        → passed as an HTML/CSS height attribute

Shared preamble (e.g. #import statements) can be declared once with a
{.typst-embed-setup} block.  Its content is prepended to every typst-embed
block in the document and the block itself is removed from the output.

Relative #import paths are resolved from the document's working directory.

The Typst executable is resolved in this order:
  1. TYPST_BIN environment variable
  2. `quarto typst` (when Quarto >= 1.4 is available)
  3. `typst` on PATH
]]

local utils  = require 'pandoc.utils'
local List   = require 'pandoc.List'
local stringify = utils.stringify

-- ---------------------------------------------------------------------------
-- Resolve the typst executable
-- ---------------------------------------------------------------------------

--- Like pandoc.pipe but accepts a List as the command, allowing
--- "multi-word" executables such as List{'quarto', 'typst'}.
local function pipe(command, args, input)
  local cmd
  if pandoc.utils.type(command) == 'List' then
    command = command:map(stringify)
    cmd = command:remove(1)   -- mutates the list in place
    args = command .. args    -- prepend remaining words to args
  else
    cmd = stringify(command)
  end
  return pandoc.pipe(cmd, args, input)
end

local function resolve_typst()
  local from_env = os.getenv('TYPST_BIN')
  if from_env and from_env ~= '' then return from_env end
  if quarto and quarto.version >= '1.4' then
    return List{'quarto', 'typst'}
  end
  return 'typst'
end

local typst_exec = resolve_typst()

-- ---------------------------------------------------------------------------
-- Shared preamble (populated by typst-embed-setup blocks)
-- ---------------------------------------------------------------------------

local shared_preamble = ''

-- ---------------------------------------------------------------------------
-- Option parsing
-- ---------------------------------------------------------------------------

--- Parse  //| key: value  lines from a code block.
-- Returns two values:
--   props  – table of key→value pairs
--   code   – the block text with the option lines removed
local function parse_options(text)
  local props = {}
  local kept  = {}
  for line in (text .. '\n'):gmatch('([^\n]*)\n') do
    local key, value = line:match('^//|%s*([-_%w]+):%s*(.-)%s*$')
    if key then
      props[key] = value
    else
      kept[#kept + 1] = line
    end
  end
  -- gmatch adds a trailing empty entry; drop it
  if kept[#kept] == '' then kept[#kept] = nil end
  return props, table.concat(kept, '\n')
end

-- ---------------------------------------------------------------------------
-- Compilation
-- ---------------------------------------------------------------------------

--- SVGs are written here so Pandoc/RevealJS can reference them as files.
local output_dir = '_typst-embed'

--- In-memory deduplication: maps sha1(code) → svg path.
-- Populated during a render; discarded afterwards, so imported .typ files are
-- always re-read on the next render.
local compiled_cache = {}

--- Compile Typst source to SVG.
-- Writes a temporary .typ file in the *current working directory* so that
-- relative #import paths in the code are resolved correctly, then deletes it.
-- Returns the SVG path, or nil on error.
local function compile_typst(code)
  local hash = pandoc.utils.sha1(code)

  if compiled_cache[hash] then return compiled_cache[hash] end

  pandoc.system.make_directory(output_dir, true)
  local src = hash .. '.typ'
  local out = pandoc.path.join{output_dir, hash .. '.svg'}

  local f = io.open(src, 'w')
  f:write(code)
  f:close()

  local ok, err = pcall(pipe, typst_exec,
    {'compile', '--format', 'svg', src, out}, '')
  os.remove(src)  -- always clean up, whether compilation succeeded or not

  if not ok then
    warn('typst-embeds: compilation failed – ' .. tostring(err))
    return nil
  end

  compiled_cache[hash] = out
  return out
end

-- ---------------------------------------------------------------------------
-- Filter
-- ---------------------------------------------------------------------------

function CodeBlock(el)
  -- Setup block: accumulate shared preamble, remove block from output
  if el.classes:includes('typst-embed-setup') then
    shared_preamble = shared_preamble .. el.text .. '\n'
    return {}  -- removes the block
  end

  if not el.classes:includes('typst-embed') then return nil end

  -- 1. Pull //| options out of the block text
  local props, clean_code = parse_options(el.text)

  -- 2. Code-block attributes override //| options (consistent with Quarto)
  for k, v in pairs(el.attributes) do
    props[k] = v
  end

  -- 3. Prepend the page preamble + shared preamble and compile
  local preamble   = '#set page(width: auto, height: auto, margin: 1pt)\n'
  local typst_code = preamble .. shared_preamble .. clean_code

  local img_path = compile_typst(typst_code)
  if not img_path then return nil end

  -- 4. Build image attributes
  local img_attr   = {}
  local img_classes = List{}

  if props['width']  then img_attr['width']  = props['width']  end
  if props['height'] then img_attr['height'] = props['height'] end

  -- When the user has explicitly sized the image, prevent RevealJS from
  -- overriding those dimensions with its auto-stretch behaviour (which adds
  -- the r-stretch class and replaces width/height with computed pixel values).
  if props['width'] or props['height'] then
    img_classes:insert('nostretch')
  end

  -- 5. Alt text comes from the caption (if any)
  local caption_text = props['fig-cap']
  local alt = caption_text and pandoc.read(caption_text).inlines or {}

  local image = pandoc.Image(alt, img_path, '', img_attr)
  image.classes = img_classes

  -- 6. Wrap in Figure when a caption is present; otherwise a plain Para
  if caption_text then
    local caption_blocks = pandoc.read(caption_text).blocks
    return pandoc.Figure(pandoc.Plain{image}, caption_blocks)
  end

  return pandoc.Para{image}
end