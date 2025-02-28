// Functions for encoding lists/table columns as small data types

// Start position and max number of encodable values by data type
// short and int can have 1+2*0W values due to zero and negatives
encodingtypes:`byte`char`short`int!`start`maxvals!/:(0 256; 0 256; -32767 65535; -2147483647 4294967295)

// Encode an atom or list of values as a data type with a smaller size using an on-disk mapping dictionary
// Like .Q.en but for a single column
// Mapping file is created if it doesn't exist and extended if necessary (and possible)
// Values can have mixed types
encode:{[encodingtype;mappingfile;vals]
  // Get or initialize mapping
  mapping:$[()~key mappingfile;()!encodingtype$();get mappingfile];
  // Error if the mapping is for a different data type
  if[(type value mapping)<>type encodingtype$();'`type];
  // Check for new values
  newvals:dv where not (dv:distinct vals,()) in key mapping;
  if[n:count newvals;
    // Error if trying to extend mapping beyond data type domain
    if[(n+m:count mapping)>encodingtypes[encodingtype;`maxvals];'`domain];
    // Else extend mapping
    -1 "Adding ", string[n], " new value(s) to ", string mappingfile;
    // Use "til n" to generate next n encodings
    mapping,:newmapping:newvals!encodingtype$encodingtypes[encodingtype;`start]+m+til n;
    mappingfile upsert newmapping];
  // Return encoded values
  mapping[vals]
  }

byteencode:encode[`byte]
charencode:encode[`char]
shortencode:encode[`short]
intencode:encode[`int]
