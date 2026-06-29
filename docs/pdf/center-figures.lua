-- center-figures.lua
-- For PDF (LaTeX) output: center standalone diagrams and render the
-- "Figure N — ..." caption lines as small, grey, centered italics —
-- matching the original .docx. No-op for non-LaTeX targets.

if FORMAT == nil or not FORMAT:match("latex") then
  return {}
end

function Para(el)
  -- A paragraph that is just one image -> center it.
  if #el.content == 1 and el.content[1].t == "Image" then
    return {
      pandoc.RawBlock("latex", "\\begin{center}"),
      el,
      pandoc.RawBlock("latex", "\\end{center}"),
    }
  end

  -- A "Figure N ..." caption line -> centered, small, grey.
  local txt = pandoc.utils.stringify(el)
  if txt:match("^Figure %d") then
    return {
      pandoc.RawBlock("latex", "\\begin{center}\\small\\color{captiongray}"),
      pandoc.Plain(el.content),
      pandoc.RawBlock("latex", "\\end{center}"),
    }
  end
end
