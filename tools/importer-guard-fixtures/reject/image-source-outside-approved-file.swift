import ImageIO

func count(_ data: Data) -> Int {
  CGImageSourceCreateWithData(data as CFData, nil).map(CGImageSourceGetCount) ?? 0
}
