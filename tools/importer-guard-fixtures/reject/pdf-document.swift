import PDFKit

func pages(_ data: Data) -> Int { PDFDocument(data: data)?.pageCount ?? 0 }
