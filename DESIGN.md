Idea is that I would like to have a search tool that maps all files that match
a glob into memory, then divides that memory equally for each availble thread
goes over that memory and uses SIMD to search.

Because this tool inherently has the goal of searching code, it might not support
full-on normal searching capabilities:
- almost for sure no full regex support (maybe some simple stuff like a '.' or '*')
- maybe even supporting searching only upto the first match per line, which would
  also have the added bonus of increasing performance on lines that in fact match
  the user query
- query has to be longer than 1 character
- no support for UTF-8 (especially no full support, probably ever)
