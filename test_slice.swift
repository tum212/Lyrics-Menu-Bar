var a = [Float]([1, 2, 3, 4])
var b = [Float](repeating: 0, count: 2)
b[0..<2] = a[2..<4]
print(b)
