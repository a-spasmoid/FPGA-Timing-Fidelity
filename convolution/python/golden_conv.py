def conv3x3(pixels, kernel):
    assert len(pixels) == 9
    assert len(kernel) == 9
    return sum(pixels[i] * kernel[i] for i in range(9))


pixels = [
    10, 20, 30,
    40, 50, 60,
    70, 80, 90
]

kernel = [
     1,  0, -1,
     1,  0, -1,
     1,  0, -1
]

print(conv3x3(pixels, kernel))
