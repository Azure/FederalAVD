param name string = 'vdpool-identifier-location'
param name2 string = 'vdpool-identifier-index-location'
param name3 string = 'identifier-location-vdpool'
param name4 string = 'identifier-index-location-vdpool'
param name5 string = 'vdpool-ident-fier-location'
param name6 string = 'vdpool-ident-fier-index-location'
param name7 string = 'ident-fier-location-vdpool'
param name8 string = 'ident-fier-index-location-vdpool'
param nameempty string = ''
var arrname = split(name, '-')
var arrname2 = split(name2, '-')
var arrname3 = split(name3, '-')
var arrname4 = split(name4, '-')
var arrname5 = split(name5, '-')
var arrname6 = split(name6, '-')
var arrname7 = split(name7, '-')
var arrname8 = split(name8, '-')
var arrnameempty = split(nameempty, '-')

var arrayEmpty = []
var arrayElement = [
  'firstelement'
]

output arrname array = arrname
output lengtharrname int = length(arrname)
output arrname2 array = arrname2
output lengtharrname2 int = length(arrname2)
output arrname3 array = arrname3
output lengtharrname3 int = length(arrname3)
output arrname4 array = arrname4
output lengtharrname4 int = length(arrname4)
output arrname5 array = arrname5
output lengtharrname5 int = length(arrname5)
output arrname6 array = arrname6
output lengtharrname6 int = length(arrname6)
output arrname7 array = arrname7
output lengtharrname7 int = length(arrname7)
output arrname8 array = arrname8
output lengtharrname8 int = length(arrname8)
output arrnameempty array = arrnameempty
output lengtharrnameempty int = length(arrnameempty)
output last string = last(arrnameempty)
output outputarray array = union(arrayEmpty, arrayElement)
