# bootc v1.16.13 BootEntry: backend state is a sibling of image, not inside it.
.status.booted
| if type != "object" then error("missing booted BootEntry")
  elif (.composefs | type) == "object" and .ostree == null then "composefs"
  elif (.ostree | type) == "object" and .composefs == null then "ostree"
  else error("missing or ambiguous booted backend")
  end
