// WECA Report Template for Quarto
// West of England Combined Authority branded report

// --- Color Definitions ---
#let weca-forest-green = rgb("#1D4F2B")
#let weca-west-green = rgb("#40A832")
#let weca-black = rgb("#1F1F1F")
#let weca-grey = rgb("#3C3C3C")
#let weca-warm-grey = rgb("#A6A6A5")
#let weca-soft-green = rgb("#8FCC87")
#let weca-light-green = rgb("#F0F7F1")

// --- Main Document Function ---
#let weca-report(
  title: none,
  subtitle: none,
  authors: none,
  date: none,
  abstract: none,
  abstract-title: none,
  cols: 1,
  lang: "en",
  region: "GB",
  font: ("Open Sans",),
  fontsize: 11pt,
  title-size: 1.5em,
  subtitle-size: 1.25em,
  heading-family: ("Avenir", "Open Sans"),
  heading-weight: "bold",
  heading-style: "normal",
  heading-color: weca-forest-green,
  heading-line-height: 0.65em,
  sectionnumbering: none,
  toc: false,
  toc_title: none,
  toc_depth: none,
  toc_indent: 1.5em,
  paper: "a4",
  margin: (top: 2.5cm, bottom: 2cm, left: 2cm, right: 2cm),
  pagenumbering: "1",
  doc,
) = {
  // Base text settings
  set par(justify: true)
  set text(
    lang: lang,
    region: region,
    font: font,
    size: fontsize,
    fill: weca-black,
  )
  set heading(numbering: sectionnumbering)

  // --- Title Page ---
  if title != none {
    page(
      paper: paper,
      margin: 0cm,
      header: none,
      footer: none,
      numbering: none,
      background: {
        // White upper area (~35%)
        place(top, box(width: 100%, height: 35%, fill: white))
        // Forest Green band (~50%)
        place(top + left, dy: 35%, box(width: 100%, height: 50%, fill: weca-forest-green))
        // White bottom strip (~15%)
        place(bottom, box(width: 100%, height: 15%, fill: white))
        // West Green accent line at junction
        place(top + left, dy: 85%, line(length: 100%, stroke: 3pt + weca-west-green))
      },
    )[
      // Logo in white upper area
      #place(top + center, dy: 8%)[
        #image("_extensions/weca-report/assets/logo.png", width: 2.2in)
      ]

      // Title content in green band
      #place(top + center, dy: 38%)[
        #block(width: 80%)[
          #set align(center)
          #set text(fill: white, font: heading-family)
          #set par(leading: 0.65em)
          #text(size: 28pt, weight: "bold")[#title]
          #if subtitle != none {
            v(0.8em)
            text(size: 18pt, weight: "regular")[#subtitle]
          }
          #if authors != none {
            v(1.2em)
            for author in authors {
              text(size: 13pt, weight: "regular")[#author.name]
              if author.at("affiliation", default: none) != none and author.affiliation != [] {
                text(size: 11pt, weight: "regular")[\ #author.affiliation]
              }
              linebreak()
            }
          }
          #if date != none {
            v(0.8em)
            text(size: 13pt, weight: "regular")[#date]
          }
        ]
      ]
    ]
  }

  // Reset page counter after title page
  counter(page).update(1)

  // --- Content Page Setup ---
  set page(
    paper: paper,
    margin: margin,
    numbering: pagenumbering,
    // Running header
    header: context {
      if title != none {
        set text(size: 9pt, fill: weca-grey)
        title
        v(-2pt)
        line(length: 100%, stroke: 0.5pt + weca-forest-green)
      }
    },
    // Footer with page number
    footer: context {
      line(length: 100%, stroke: 0.5pt + weca-warm-grey)
      v(4pt)
      align(center)[
        #set text(size: 9pt, fill: weca-grey)
        #counter(page).display(pagenumbering)
      ]
    },
  )

  // --- Heading Styles ---
  // H1: Forest Green, 20pt bold, with underline accent; always starts on a new page
  show heading.where(level: 1): it => {
    pagebreak(weak: true)
    set text(
      font: heading-family,
      fill: weca-forest-green,
      size: 20pt,
      weight: "bold",
    )
    v(0.8em)
    it
    v(-0.2em)
    line(length: 100%, stroke: 1.5pt + weca-forest-green)
    v(0.4em)
  }

  // H2: West Green, 16pt bold
  show heading.where(level: 2): it => {
    set text(
      font: heading-family,
      fill: weca-west-green,
      size: 16pt,
      weight: "bold",
    )
    v(0.6em)
    it
    v(0.3em)
  }

  // H3: WECA Black, 13pt bold
  show heading.where(level: 3): it => {
    set text(
      font: heading-family,
      fill: weca-black,
      size: 13pt,
      weight: "bold",
    )
    v(0.4em)
    it
    v(0.2em)
  }

  // H4: Grey, 12pt bold italic
  show heading.where(level: 4): it => {
    set text(
      font: heading-family,
      fill: weca-grey,
      size: 12pt,
      weight: "bold",
      style: "italic",
    )
    v(0.3em)
    it
    v(0.2em)
  }

  // --- Abstract ---
  if abstract != none {
    block(
      width: 100%,
      inset: (left: 12pt, right: 12pt, top: 10pt, bottom: 10pt),
      fill: weca-light-green,
      stroke: (left: 3pt + weca-west-green),
      radius: (right: 4pt),
    )[
      #if abstract-title != none {
        text(weight: "bold", fill: weca-forest-green)[#abstract-title]
        parbreak()
      }
      #abstract
    ]
    v(1em)
  }

  // --- Table of Contents ---
  if toc {
    block(above: 0em, below: 2em)[
      #text(size: 16pt, weight: "bold", fill: weca-forest-green)[
        #if toc_title != none { toc_title } else { [Contents] }
      ]
      #v(0.5em)
      #outline(
        title: none,
        depth: toc_depth,
        indent: toc_indent,
      )
    ]
  }

  // --- Links ---
  show link: it => {
    set text(fill: weca-west-green)
    underline(it)
  }

  // --- Tables ---
  set table(
    inset: 8pt,
    stroke: 0.5pt + weca-warm-grey,
  )
  show table: it => {
    set text(size: 10pt)
    it
  }

  // --- Content ---
  if cols == 1 {
    doc
  } else {
    columns(cols, doc)
  }
}

// --- Table Styling (global show rules) ---
#set table(
  inset: 6pt,
  stroke: none,
  fill: (_, y) => {
    if y == 0 { weca-forest-green }
    else if calc.odd(y) { weca-light-green }
    else { white }
  },
)

// Style header row text
#show table.cell.where(y: 0): set text(fill: white, weight: "bold")

// --- Code Block Styling ---
#show raw.where(block: true): set block(
  fill: rgb("#F5F5F5"),
  width: 100%,
  inset: 10pt,
  radius: 4pt,
  stroke: 0.5pt + rgb("#E0E0E0"),
)
#show raw.where(block: true): set text(
  font: ("Fira Code", "DejaVu Sans Mono"),
  size: 9.5pt,
)

// --- Inline Code Styling ---
#show raw.where(block: false): box.with(
  fill: rgb("#EEEEEE"),
  inset: (x: 4pt, y: 2pt),
  outset: (y: 2pt),
  radius: 3pt,
)
#show raw.where(block: false): set text(size: 0.9em)

// --- Blockquote Styling ---
#let blockquote(body) = [
  #set text(size: 0.92em, fill: weca-grey)
  #block(
    inset: (left: 1.5em, top: 0.2em, bottom: 0.2em),
    stroke: (left: 2pt + weca-warm-grey),
  )[#body]
]

#let horizontalrule = line(start: (25%, 0%), end: (75%, 0%), stroke: 0.5pt + weca-warm-grey)

#let endnote(num, contents) = [
  #stack(dir: ltr, spacing: 3pt, super[#num], contents)
]

#show terms: it => {
  it
    .children
    .map(child => [
      #strong[#child.term]
      #block(inset: (left: 1.5em, top: -0.4em))[#child.description]
    ])
    .join()
}
