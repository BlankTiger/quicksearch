Idea is that I would like to have a search tool that maps all files that match
a glob into memory, then divides that memory equally for each availble thread
goes over that memory and uses SIMD to search.
