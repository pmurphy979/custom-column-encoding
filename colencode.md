# Column encoding

``` q
// kdb+ version info
q).z.K
4.1
q).z.k
2024.07.08
```

[For optimization reasons](https://code.kx.com/q/wp/symfiles/#enumeration), kdb+ does not allow splayed tables to have unenumerated symbol columns.

The conventional method is to enumerate all symbol columns in a table with a single file (typically called `sym`) containing the enumeration domain as a list of distinct symbols. This is what the [`.Q.en`](https://code.kx.com/q/ref/dotq/#en-enumerate-varchar-cols) function does.

Since [kdb+ 3.6](https://code.kx.com/q/releases/ChangesIn3.6/#64-bit-enumerations), each enumerated value is encoded as a `long` (signed 64 bit) integer corresponding to its index in the domain list. The total number of symbols that can be encoded this way is therefore `(2^64)-1` (over 18 quintillion)! Obviously, a real-life enumeration domain will never reach anywhere remotely near this length. Also, since the entire `sym` file is routinely loaded into memory, memory space becomes a concern much sooner than domain space.

Why use a 64 bit encoding if most of the bits are never used? One reason might be to avoid having to worry about domain space at all. However, as long as we stay conscious of the domain limit, encoding with a data type with a smaller number of bits can give us less disk usage, less memory usage, and faster queries.

Additionally, since symbol columns can have very different cardinalities, we can break from the single `sym` file convention and encode each individual column with a data type of the smallest possible domain size.

The prime data type candidates with fewer than 64 bits are summarized below, along with `long` for comparison:

type | size (bits) | domain size | domain size (explicit)
---|---|---|---
byte | 8 | `2^8` | 256
char | 8 | `2^8` | 256
short | 16 | `(2^16)-1` | 65,535
int | 32 | `(2^32)-1` | 4,294,967,295
long | 64 | `(2^64)-1` | 18,446,744,073,709,551,615

`byte` and `char` data types have the same number of bits and the same domain size, so the choice between them is fairly arbitrary.

`month`, `date`, `minute`, `second`, and `time` data types are represented internally by 32 bit integers as well so could also be used, but `int` seems a more natural choice.

## Encoding function

The `colencode.q` script defines a function `encode` which is similar to `.Q.en`, but works on a single atom or list rather than on an entire table. It takes three arguments:
1. A data type to use for encoding (the allowed values are `byte`, `char`, `short`, or `int`)
2. A mapping dictionary file to create/use/extend (similar to the `sym` file created/used/extended by `.Q.en`)
3. An atom or list of values to encode

The mapping dictionary is a one-to-one kdb+ dictionary which maps the set of unencoded values to the set of encoded values.

The function takes the following steps:
1. Loads the mapping file if it exists, otherwise creates an empty mapping dictionary
2. Raises a `'type` error if the file already exists and doesn't match the chosen data type (while it is possible to have a dictionary with mixed types, splayed table columns should be simple lists, and enforcing a single data type keeps the domain space calculation in step 4 simple)
3. Finds any input values not already in the mapping and assigns them unique values in the chosen data type
4. Raises a `'domain` error if there aren't enough unique values left in the domain space
5. Updates the mapping on disk
6. Returns an atom or list of encoded values which corresponds one-to-one with the atom or list of input values

To assign new values in the right-hand side of a mapping in step 2, `til n` is used to generate a sequence of `n` longs from `0` to `n-1`, which are shifted left along the number line as far as the chosen encoding type will allow - for `byte` and `char` there is no shift at all, while for `short` and `int`, values are shifted by `-0Wh` and `-0Wi` respectively. Values are then shifted right by the number of values already in the mapping. This ensures no overlap between new and existing values (since the mapping should be strictly one-to-one) and no gap between them either (to make maximum use of the domain space available). The final set of longs are then cast to the chosen encoding type.

Rather than storing unencoded and encoded values as a dictionary, it would also be possible to store just the unencoded values as a list (like in a `sym` file), and have functions which encode/decode values according to their indexes in this list. While this would reduce the on-disk and in-memory size of the mappings even further, it would lead to some additional time and space overhead in queries involving encoding/decoding. As shown below, using dictionaries can still provide considerable [disk](#disk-usage) and [memory](#memory) savings.

The script also defines a projected version of the `encode` function for each of the four supported datatypes: `byteencode`, `charencode`, `shortencode`, and `intencode`.

## Vector encoding

To test the encoding function, let's first apply it to a simple list of values.

``` q
q)\l colencode.q
q)show v:10?10
8 1 9 5 4 6 6 1 8 5

// Encode elements of v as characters and save the mapping dictionary as a file called v2c
q)show cv:charencode[`:v2c] v
Adding 6 new value(s) to :v2c
"\000\001\002\003\004\005\005\001\000\003"

// Load mapping file to encode v on demand
q)load `:v2c
`v2c
q)string v2c
8| ,"\000"
1| ,"\001"
9| ,"\002"
5| ,"\003"
4| ,"\004"
6| ,"\005"
q)cv ~ v2c v
1b

// Use a reverse dictionary lookup to decode
q)v ~ v2c? cv
1b
q)v ~ v2c? v2c v
1b

// Unknown values map to null characters (spaces)
q)show v:v,10?20
8 1 9 5 4 6 6 1 8 5 4 13 9 2 7 0 17 14 9 18
q)v2c v
"\000\001\002\003\004\005\005\001\000\003\004 \002     \002 "

// Extend mapping
q)show cv:charencode[`:v2c] v
Adding 7 new value(s) to :v2c
"\000\001\002\003\004\005\005\001\000\003\004\006\002\007\010\t\n\013\002\014"

// Need to reload v2c to pick up changes
q)cv ~ v2c v
0b
q)load `:v2c
`v2c
q)cv ~ v2c v
1b

// A char mapping can hold up to 256 distinct values
q)charencode[`:v2c] til 257
'domain
q)charencode[`:v2c] til 256;
Adding 243 new value(s) to :v2c

// v2c is now full and won't accept any more new values
q)charencode[`:v2c] 256
'domain
q)charencode[`:v2c] 257
'domain
q)charencode[`:v2c] 88
"X"

// File size of v2c is consistent with 256 pairs of 8 bytes (long) + 1 byte (char) and 15 bytes dictionary overhead
q)hcount `:v2c
2319
q)256*8+1
2304

// A short mapping can hold up to 65535 distinct values
q)hv:shortencode[`:v2h] v
Adding 13 new value(s) to :v2h
q)5#hv
-0W -32766 -32765 -32764 -32763h
q)load `:v2h
`v2h
q)5#v2h
8 | -0W
1 | -32766
9 | -32765
5 | -32764
4 | -32763
q)hv ~ v2h v
1b
q)shortencode[`:v2h] til 65536;
'domain
q)shortencode[`:v2h] til 65535;
Adding 65522 new value(s) to :v2h
q)load `:v2h
`v2h
q)count v2h
65535
q)-5#v2h
65530| 32763
65531| 32764
65532| 32765
65533| 32766
65534| 0W

// File size of v2h is consistent with 65535 pairs of 8 bytes (long) + 2 bytes (short) and 15 bytes dictionary overhead
q)hcount `:v2h
655365
q)65535*8+2
655350

// An int mapping can hold up to 4294967295 distinct values (but probably shouldn't)
q)iv:intencode[`:v2i] v
Adding 13 new value(s) to :v2i
q)5#iv
-0W -2147483646 -2147483645 -2147483644 -2147483643i
q)load `:v2i
`v2i
q)iv ~ v2i v
1b
q)intencode[`:v2i] til 100000;
Adding 99987 new value(s) to :v2i
q)intencode[`:v2i] til 1000000;
Adding 900000 new value(s) to :v2i
q)intencode[`:v2i] til 42949672;
Adding 41949672 new value(s) to :v2i

// File size of v2i is consistent with 42949672 pairs of 8 bytes (long) + 4 bytes (int) and 15 bytes dictionary overhead
q)hcount `:v2i
515396079
q)42949672*8+4
515396064

// Max theoretical size of v2i in GB
q)1e-9*15+4294967295*8+4
51.53961

// Can't encode with data types not in encodingtypes
q)encodingtypes
     | start       maxvals   
---- | ----------------------
byte | 0           256       
char | 0           256       
short| -32767      65535     
int  | -2147483647 4294967295

q)encode[`long;`:v2j] v
'type

// Encoding type must match type of values mapping file
q)intencode[`:v2h] v
'type
```

## Table encoding

Now we know the `encode` function works as expected, let's apply it to the columns of a table.

The _data types_ of the unencoded columns don't matter much for the purpose of testing, since the only data types affecting disk/memory usage and query performance will be those of the encoded values. However, their _cardinalities_ matter a lot, since they determine the cardinalities of the encoded columns and what data types can be used for encoding. For these reasons, let's keep things simple and define a table of symbol columns of varying cardinality.

``` q
q)n:5000000 // 5M rows

// Number of characters in each symbol column determines column cardinality
q)5# tab: ([] sym1:n?`1; sym2:n?`2; sym3:n?`3; sym4:n?`4; sym5:n?`5)
sym1 sym2 sym3 sym4 sym5 
-------------------------
j    fa   icl  djab ofnib
h    hn   bak  pfaj njdag
g    ff   pig  ndmb eofdl
p    fd   mpa  hlik odada
i    ge   afh  bpkm ncgbg

// Column cardinalities
q)count each distinct each flip tab
sym1| 16
sym2| 256
sym3| 4096
sym4| 65536
sym5| 1039745
```

Note that in general the cardinality of the `symx` column is `16^x`, since each value is composed of `x` hexadecimal characeters. Except for `sym5` that is, since 5M random draws from a set of `16^5 = 1,048,576` distinct values is not quite enough to encompass the full set.

The `sym2` column therefore has `256` distinct values, which makes it just about viable for `char` encoding, as there are also `256` distinct `char` values.

On the other hand, the `sym4` column has `65536` distinct values and there are only `65535` distinct `short` values, so for the sake of that one value we have to use `int` instead.

Before encoding the table, let's splay a version with the columns enumerated by a conventional single `sym` file. This version will be used to benchmark the storage and query performance of the encoded table.

``` q
// Save as splayed table with columns enumerated by single sym file
q)`:testdb/enum/enumtab/ set .Q.en[`:testdb/enum] tab
`:testdb/enum/enumtab/
```

Now the version with individually encoded columns:

``` q
// Save as splayed table with columns individually encoded
q)`:testdb/encode/encodetab/ set update
    charencode[`:testdb/encode/sym1map] sym1,
    charencode[`:testdb/encode/sym2map] sym2,
    shortencode[`:testdb/encode/sym3map] sym3,
    shortencode[`:testdb/encode/sym4map] sym4,
    intencode[`:testdb/encode/sym5map] sym5
    from tab
Adding 16 new value(s) to :testdb/encode/sym1map
Adding 256 new value(s) to :testdb/encode/sym2map
Adding 4096 new value(s) to :testdb/encode/sym3map    
'domain
```

I forgot we can't use `short` for `sym4`. Let's try that again.

``` q
q)`:testdb/encode/encodetab/ set update
    charencode[`:testdb/encode/sym1map] sym1,
    charencode[`:testdb/encode/sym2map] sym2,
    shortencode[`:testdb/encode/sym3map] sym3,
    intencode[`:testdb/encode/sym4map] sym4,
    intencode[`:testdb/encode/sym5map] sym5
    from tab
Adding 65536 new value(s) to :testdb/encode/sym4map
Adding 1039745 new value(s) to :testdb/encode/sym5map
`:testdb/encode/encodetab/
```

## Comparison

### Disk usage

First off, the total file size of the column-encoded directory is 65% smaller:

``` bash
$ du -sh testdb/*
68M     testdb/encode
198M    testdb/enum
```

Next let's look at the sizes of the tables, sym file, and dictionary mappings within each directory:

``` bash
$ du -sh testdb/enum/*
191M    testdb/enum/enumtab
6.3M    testdb/enum/sym

$ du -sh testdb/encode/*
58M     testdb/encode/encodetab
4.0K    testdb/encode/sym1map
4.0K    testdb/encode/sym2map
28K     testdb/encode/sym3map
580K    testdb/encode/sym4map
10M     testdb/encode/sym5map
```

Between them, the dictionary mappings contain the same set of symbols as the `sym` file, but due to the fact they are dictionaries with a char/short/int value for every symbol, the combined file size of the dictionary mappings is ~70% larger than that of the `sym` file, which is a simple list of symbols.

However, the column-encoded table is ~70% smaller, because the encoding uses data types with smaller byte sizes than the long integers used in the enumerated table.

This is especially evident from looking at the individual column file sizes:

``` bash
$ du -sh testdb/enum/enumtab/*
39M     testdb/enum/enumtab/sym1
39M     testdb/enum/enumtab/sym2
39M     testdb/enum/enumtab/sym3
39M     testdb/enum/enumtab/sym4
39M     testdb/enum/enumtab/sym5

$ du -sh testdb/encode/encodetab/*
4.8M    testdb/encode/encodetab/sym1
4.8M    testdb/encode/encodetab/sym2
9.6M    testdb/encode/encodetab/sym3
20M     testdb/encode/encodetab/sym4
20M     testdb/encode/encodetab/sym5
```

### Loading

The procedure for loading the two tables is practically the same, since q knows to load every file in the directory it is given, whether that includes a single `sym` file or a set of mapping files.

The obvious difference is that, once the loaded tables are looked at, the enumerated version is automatically decoded and human readable, while the encoded version is not.

<table>
<tr>
<th>Enumerated</th>
<th>Column-encoded</th>
</tr>
<tr>
<td>

``` q
q)\l testdb/enum

q)count enumtab
5000000

q)meta enumtab
c   | t f a
----| -----
sym1| s    
sym2| s    
sym3| s    
sym4| s    
sym5| s    




q)count sym
1109649

q)5# enumtab
sym1 sym2 sym3 sym4 sym5 
-------------------------
j    fa   icl  djab ofnib
h    hn   bak  pfaj njdag
g    ff   pig  ndmb eofdl
p    fd   mpa  hlik odada
i    ge   afh  bpkm ncgbg


q)5# enumtab
sym1 sym2 sym3 sym4 sym5 
-------------------------
j    fa   icl  djab ofnib
h    hn   bak  pfaj njdag
g    ff   pig  ndmb eofdl
p    fd   mpa  hlik odada
i    ge   afh  bpkm ncgbg





q)count each distinct each flip enumtab
sym1| 16
sym2| 256
sym3| 4096
sym4| 65536
sym5| 1039745

q)\ts count each distinct each flip enumtab
128 76616608
```
</td>
<td>

``` q
q)\l testdb/encode

q)count encodetab
5000000

q)meta encodetab
c   | t f a
----| -----
sym1| c    
sym2| c    
sym3| h    
sym4| i    
sym5| i    

q)count each (sym1map;sym2map;sym3map;sym4map;sym5map)
16 256 4096 65536 1039745

q)sum count each (sym1map;sym2map;sym3map;sym4map;sym5map)
1109649

q)5# encodetab
sym1 sym2 sym3   sym4        sym5       
----------------------------------------
        -0W    -0W         -0W        
        -32766 -2147483646 -2147483646
        -32765 -2147483645 -2147483645
        -32764 -2147483644 -2147483644
        -32763 -2147483643 -2147483643

// Need to do a reverse dictionary lookups to decode values
q)update sym1map?sym1, sym2map?sym2, sym3map?sym3, sym4map?sym4, sym5map?sym5 from 5# encodetab
sym1 sym2 sym3 sym4 sym5 
-------------------------
j    fa   icl  djab ofnib
h    hn   bak  pfaj njdag
g    ff   pig  ndmb eofdl
p    fd   mpa  hlik odada
i    ge   afh  bpkm ncgbg

// Doesn't take long to decode everything
q)\ts update sym1map?sym1, sym2map?sym2, sym3map?sym3, sym4map?sym4, sym5map?sym5 from encodetab
209 402654640

q)count each distinct each flip encodetab
sym1| 16
sym2| 256
sym3| 4096
sym4| 65536
sym5| 1039745

q)\ts count each distinct each flip encodetab
65 38290624
```
</td>
</tr>
</table>

### Memory

The memory stats below were gathered in fresh processes, immediately after loading each directory.

They show that the encoded directory uses 2.5 MB less memory, and 140 MB less mapped memory after calling [`.Q.MAP`](https://code.kx.com/q/ref/dotq/#map-maps-partitions).



<table>
<tr>
<th>Enumerated</th>
<th>Column-encoded</th>
</tr>
<tr>
<td>

``` q
q)\l testdb/enum

q).Q.w[]
used| 18735744
heap| 67108864
peak| 67108864
wmax| 0
mmap| 0
mphy| 134594002944
syms| 1112625
symw| 50090090

q).Q.MAP[]

q).Q.w[]
used| 18735792
heap| 67108864
peak| 67108864
wmax| 0
mmap| 200020480
mphy| 134594002944
syms| 1112628
symw| 50090185
```
</td>
<td>

``` q
q)\l testdb/encode

q).Q.w[]
used| 16201344
heap| 67108864
peak| 67108864
wmax| 0
mmap| 0
mphy| 134594002944
syms| 1112634
symw| 50090404

q).Q.MAP[]

q).Q.w[]
used| 16201392
heap| 67108864
peak| 67108864
wmax| 0
mmap| 60000080
mphy| 134594002944
syms| 1112638
symw| 50090528
```
</td>
</tr>
</table>

### Filtering

`select from table where...` queries are faster on encoded columns than their enumerated counterparts.

The only downside is that a user needs to encode any human-readable input values using the corresponding dictionary mapping (and decode outputs if necessary).

The extent of the performance boost depends on a number of related factors: the cardinality of the filter column, the number of results returned, and the byte size of the encoded values.

Unlike the enumerated table, the search time for the encoded table decreases monotonically with the number of positive matches.

<table>
<tr>
<th>Enumerated</th>
<th>Column-encoded</th>
</tr>
<tr>
<td>

``` q
q)count select from enumtab where sym1=`a
312500

q)\ts:100 select from enumtab where sym1=`a
4476 75498160

q)count select from enumtab where sym2=`ab
19468

q)\ts:100 select from enumtab where sym2=`ab
2817 75498160

q)count select from enumtab where sym3=`abc
1280

q)\ts:100 select from enumtab where sym3=`abc
2603 75498160

q)count select from enumtab where sym4=`abcd
82

q)\ts:100 select from enumtab where sym4=`abcd
1762 75498160

q)count select from enumtab where sym5=`abcde
1

q)\ts:100 select from enumtab where sym5=`abcde
3379 75498160
```
</td>
<td>

``` q
q)count select from encodetab where sym1=sym1map`a
312500

q)\ts:100 select from encodetab where sym1=sym1map`a
1389 12583680

q)count select from encodetab where sym2=sym2map`ab
19468

q)\ts:100 select from encodetab where sym2=sym2map`ab
588 8651520

q)count select from encodetab where sym3=sym3map`abc
1280

q)\ts:100 select from encodetab where sym3=sym3map`abc
546 8405760

q)count select from encodetab where sym4=sym4map`abcd
82

q)\ts:100 select from encodetab where sym4=sym4map`abcd
486 8390400

q)count select from encodetab where sym5=sym5map`abcde
1

q)\ts:100 select from encodetab where sym5=sym5map`abcde
421 8389408
```
</td>
</tr>
</table>

### Grouping

`select by...from table` queries are also faster on encoded columns than their enumerated counterparts.

<table>
<tr>
<th>Enumerated</th>
<th>Column-encoded</th>
</tr>
<tr>
<td>

``` q
q)\ts select by sym1 from enumtab
33 67111424

q)\ts select by sym2 from enumtab
35 67134464

q)\ts select by sym3 from enumtab
35 67503104

q)\ts select by sym4 from enumtab
66 73401344

q)\ts select by sym5 from enumtab
841 117441536

q)\ts select rows:count i by sym1, sym2, sym3, sym4, sym5 from enumtab
4296 872418528

// select count distinct sym2,...,count distinct sym5 by sym1 from enumtab
q)\ts ?[enumtab;();enlist[`sym1]!enlist[`sym1];{x!{(count;(distinct;x))} each x}`sym2`sym3`sym4`sym5]
204 201339888

q)\ts ?[enumtab;();enlist[`sym1]!enlist[`sym2];{x!{(count;(distinct;x))} each x}`sym1`sym3`sym4`sym5]
322 201374448

q)\ts ?[enumtab;();enlist[`sym1]!enlist[`sym3];{x!{(count;(distinct;x))} each x}`sym1`sym2`sym4`sym5]
526 201927408

q)\ts ?[enumtab;();enlist[`sym1]!enlist[`sym4];{x!{(count;(distinct;x))} each x}`sym1`sym2`sym3`sym5]
969 208013040

q)\ts ?[enumtab;();enlist[`sym1]!enlist[`sym5];{x!{(count;(distinct;x))} each x}`sym1`sym2`sym3`sym4]
4021 319172016



q)5# desc select rows:count sym5 by sym5 from enumtab
sym5 | rows
-----| ----
mpohd| 19  
bifbn| 17  
domlp| 17  
eafea| 17  
egcjd| 17

q)\ts 5# desc select rows:count sym5 by sym5 from enumtab
686 100672720










```
</td>
<td>

``` q
q)\ts select by sym1 from encodetab
14 31920

q)\ts select by sym2 from encodetab
10 37296

q)\ts select by sym3 from encodetab
14 5841840

q)\ts select by sym4 from encodetab
31 69731328

q)\ts select by sym5 from encodetab
132 88081408

q)\ts select rows:count i by sym1, sym2, sym3, sym4, sym5 from encodetab
2253 608716288


q)\ts ?[encodetab;();enlist[`sym1]!enlist[`sym1];{x!{(count;(distinct;x))} each x}`sym2`sym3`sym4`sym5]
144 67161760

q)\ts ?[encodetab;();enlist[`sym1]!enlist[`sym2];{x!{(count;(distinct;x))} each x}`sym1`sym3`sym4`sym5]
232 67157152

q)\ts ?[encodetab;();enlist[`sym1]!enlist[`sym3];{x!{(count;(distinct;x))} each x}`sym1`sym2`sym4`sym5]
441 77998752

q)\ts ?[encodetab;();enlist[`sym1]!enlist[`sym4];{x!{(count;(distinct;x))} each x}`sym1`sym2`sym3`sym5]
654 125771760

q)\ts ?[encodetab;();enlist[`sym1]!enlist[`sym5];{x!{(count;(distinct;x))} each x}`sym1`sym2`sym3`sym4]
3666 224240048

// Need to do a reverse dictionary lookup to decode values in the query result
// Note different secondary sort order because decoding happened after grouping
q)update sym5map?sym5 from 5# desc select rows:count sym5 by sym5 from encodetab
sym5 | rows
-----| ----
mpohd| 19  
fbkna| 17  
fjcja| 17  
fdkeh| 17  
bifbn| 17

q)\ts 5# desc select rows:count sym5 by sym5 from encodetab
107 96478416

// If necessary, decoding should be done as late in the query as possible
q)\ts 5# desc select rows:count sym5 by sym5map?sym5 from encodetab
739 167781776

q)\ts 5# desc update sym5map?sym5 from select rows:count sym5 by sym5 from encodetab
110 96478912

q)\ts update sym5map?sym5 from 5# desc select rows:count sym5 by sym5 from encodetab
103 96478912
```
</td>
</tr>
</table>

## Extensions

### Checking mapping file capacities

A downside of encoding with smaller data type sizes is that, if we allow mapping files to grow naturally over time like the `sym` file is allowed to, then we need to keep a closer eye on the number of values in each mapping file, otherwise we might unexpectedly run out of domain space.

A regular health check like the example below could be run regularly to flag if the fraction of domain space used has reached some threshold, e.g. 90%.

``` q
q)1!{`mappingfile`encodingtype`used!(x;et;(count get x)%encodingtypes[et:key value get x;`maxvals])} each {x where x like "*map"} key `.
mappingfile| encodingtype used        
-----------| -------------------------
sym1map    | char         0.0625      
sym2map    | char         1           
sym3map    | short        0.06250095  
sym4map    | int          1.525879e-05
sym5map    | int          0.0002420845
```

`sym2map` is full! If we needed to add more `sym2` values, we would have to re-encode the column as a `short` type.

### Encoding other data types

Symbol columns work nicely for encoding because queries typically only involve filtering or grouping by value, and encoded values map one-to-one with unencoded values.

It is possible to encode non-symbol columns in exactly the same way, but certain operations that are more common with non-symbols - like pattern matching on strings and any sort of comparison/arithmetic on numerical types - cannot be performed on encoded values. For these sorts of queries, there are three options:
- Decode the values first, which may be slow and/or memory intensive depending on the query
- Perform the operation on the keys of the mapping dictionary and translate the result to the corresponding encoded values - this is potentially quicker and less memory intensive, but more unwieldy and may not work for every type of query
- Don't encode columns where these sorts of operations are common

``` q
// Create a table with 5M rows of string and long values
q)n:5000000; 5# tab: ([] c1:string n?`3; c2:n?1000)
c1    c2 
---------
"efi" 592
"gcd" 83 
"him" 630
"oco" 167
"eje" 899

// Encode the columns as shorts and splay the table
q)`:testdb/othertypes/tab/ set update
    shortencode[`:testdb/othertypes/c1map] c1,
    shortencode[`:testdb/othertypes/c2map] c2
    from tab
Adding 4096 new value(s) to :testdb/othertypes/c1map
Adding 1000 new value(s) to :testdb/othertypes/c2map
`:testdb/othertypes/tab/

// Load the splayed table and mapping files
q)\l testdb/othertypes
q)5#tab
c1     c2    
-------------
-0W    -0W   
-32766 -32766
-32765 -32765
-32764 -32764
-32763 -32763

// Need to decode c1 before doing a string pattern match
q)\ts r1: select c1 from (update c1map?c1 from tab) where c1 like "aa*"
105 134219104
q)count r1
19675
q)5# r1
c1   
-----
"aag"
"aaj"
"aab"
"aah"
"aaj"

// Slightly faster and less memory intensive
q)\ts r2: select c1map?c1 from tab where (c1map?c1) like "aa*"
80 134218976
q)r1~r2
1b

// A lot faster and less memory intensive but more unwieldy
q)\ts r3: select c1map?c1 from tab where c1 in value[c1map] where key[c1map] like "aa*"
24 75499008
q)r1~r3
1b

// Need to decode c2 before doing a value comparison
q)\ts r1: select c2 from (update c2map?c2 from tab) where c2>990
37 134219088
q)count r1
44799
q)5#r1
c2 
---
997
994
994
994
998

// Slightly faster and less memory intensive
q)\ts r2: select c2map?c2 from tab where (c2map?c2)>990
35 134218960
q)r1~r2
1b

// A lot faster and less memory intensive but more unwieldy
q)\ts r3: select c2map?c2 from tab where c2 in value[c2map] where key[c2map]>990
25 75498992
q)r1~r3
1b
```

### Multiple columns per mapping file

Provided their combined cardinality does not exceed the domain of the encoding data type, it is possible to encode multiple columns with a single mapping file (or even all columns, like with a `sym` file).

``` q
q)`:testdb/encode2/encodetab/ set update
    shortencode[`:testdb/encode2/shortmap] sym1,
    shortencode[`:testdb/encode2/shortmap] sym2,
    shortencode[`:testdb/encode2/shortmap] sym3,
    intencode[`:testdb/encode2/intmap] sym4,
    intencode[`:testdb/encode2/intmap] sym5
    from tab
Adding 16 new value(s) to :testdb/encode2/shortmap
Adding 256 new value(s) to :testdb/encode2/shortmap
Adding 4096 new value(s) to :testdb/encode2/shortmap
Adding 65536 new value(s) to :testdb/encode2/intmap
Adding 1039745 new value(s) to :testdb/encode2/intmap
`:testdb/encode2/encodetab/
```

This would be especially useful if there were a lot of overlapping values between columns in a table, (or even different tables, in which case the same mapping file could cover multiple tables), since the number of duplicate encodings (and by extension, disk and memory usage) could be minimized.

In this case, there is no overlap between the columns, so the choice to int encode `sym4` and `sym5` in the same mapping file or in separate mapping files is largely artibrary.

However, if the one-to-one relationship between columns and mapping files is broken, it could become difficult to keep track of which mapping file applies to which column. A nice feature of enumeration is that the name of the enumeration domain file is explicitly tied to the enumerated column so that encoding and decoding can happen automatically:

``` q
q)exec 5# sym1 from enumtab
`sym$`j`h`g`p`i
```

We can emulate this explicit linkage by defining a meta dictionary which maps table columns to their mapping dictionaries. This object could also be used by a function to make encoding a table a bit less verbose.

``` q
// Map column names to mapping file names
// Could nest this within a dictionary of table names for multiple tables
q)show mapmap:`sym1`sym2`sym3`sym4`sym5!`shortmap`shortmap`shortmap`intmap`intmap
sym1| shortmap
sym2| shortmap
sym3| shortmap
sym4| intmap
sym5| intmap

// Also need to define types for each mapping file when doing initial encoding (see below)
q)show maptypes:`shortmap`intmap!`short`int
shortmap| short
intmap  | int

// Function to encode columns in a table according to mapmap and maptypes
q)encodetab:{[dir;mapmap;maptypes;tab]
  // Get cols in table to encode
  mapcols:cols[tab] inter key mapmap;
  // Prepend map names with directory
  mapmap:` sv dir,/:mapcols#mapmap;
  // Update statement to encode all mapcols
  ![tab;();0b;enlist[encode;;;]'[enlist each maptypes[mapmap];enlist each mapmap;mapcols]]
  }

// Apply the function and save the result as a splayed table
q)`:testdb/encode2/encodetab/ set encodetab[`:testdb/encode2;mapmap;maptypes] tab
Adding 16 new value(s) to :testdb/encode2/shortmap
Adding 256 new value(s) to :testdb/encode2/shortmap
Adding 4096 new value(s) to :testdb/encode2/shortmap
Adding 65536 new value(s) to :testdb/encode2/intmap
Adding 1039745 new value(s) to :testdb/encode2/intmap
`:testdb/encode2/encodetab/

// Also save the mapmap object for helping with decoding
// (don't need to save maptypes since it can be easily derived from mapping files)
q)`:testdb/encode2/mapmap set mapmap
`:testdb/encode2/mapmap

// Load the table, mapping files, and mapmap
q)\l testdb/encode2

// sym2, sym3, and sym5 don't start at -0W anymore
q)5# encodetab
sym1   sym2   sym3   sym4        sym5       
--------------------------------------------
-0W    -32751 -32495 -0W         -2147418111
-32766 -32750 -32494 -2147483646 -2147418110
-32765 -32749 -32493 -2147483645 -2147418109
-32764 -32748 -32492 -2147483644 -2147418108
-32763 -32747 -32491 -2147483643 -2147418107

// Use mapmap to find the correct mapping dictionary to decode sym1
q)update get[mapmap`sym1]?sym1 from 5# encodetab
sym1 sym2   sym3   sym4        sym5       
------------------------------------------
j    -32751 -32495 -0W         -2147418111
h    -32750 -32494 -2147483646 -2147418110
g    -32749 -32493 -2147483645 -2147418109
p    -32748 -32492 -2147483644 -2147418108
i    -32747 -32491 -2147483643 -2147418107

// Use mapmap to find the correct mapping dictionary to encode sym1
q)count select from encodetab where sym5=get[mapmap`sym5]`abcde
1
```

### Anymap encodings

The need to use `get` on the mapping name in the example above doesn't hamper performance very much, but it does make this solution a bit ugly.

Rather than write individual mapping files, an alternative approach could be to write a single nested-nested-nested dictionary of structure table > column > mapping dictionary. Saving this structure as an [anymap](https://code.kx.com/q/releases/ChangesIn3.6/#anymap) object would provide the same advantages as individual mapping files, but would also allow encoding and decoding via a single object, without the need for calling `get`.

With this approach, the final two queries above become

``` q
q)update anymapmap[`encodetab;`sym1]?sym1 from 5# encodetab

q)count select from encodetab where sym5=anymapmap[`encodetab;`sym5]`abcde
```
