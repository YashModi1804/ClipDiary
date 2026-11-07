using System;
using System.IO;
using System.Security.Cryptography;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace ClipDiary.Windows.Platform;

public static class ImageCodec
{
    public static ClipboardPayload Prepare(byte[] encoded, string title, string source, DateTimeOffset capturedAt)
    {
        if (encoded.Length == 0 || encoded.Length > CapturePolicy.MaximumImageBytes || !CapturePolicy.IsPngComplete(encoded)) throw new InvalidDataException("Image is incomplete or exceeds the 25 MB item limit.");
        using var input = new MemoryStream(encoded, false);
        var decoder = BitmapDecoder.Create(input, BitmapCreateOptions.PreservePixelFormat | BitmapCreateOptions.IgnoreColorProfile, BitmapCacheOption.None);
        var frame = decoder.Frames[0];
        if (!CapturePolicy.ValidDimensions(frame.PixelWidth, frame.PixelHeight)) throw new InvalidDataException("Image exceeds the 50-megapixel limit.");
        string extension = decoder switch { PngBitmapDecoder => ".png", JpegBitmapDecoder => ".jpg", BmpBitmapDecoder => ".bmp", TiffBitmapDecoder => ".tiff", _ => throw new InvalidDataException("Unsupported image codec.") };
        var scale = Math.Min(1.0, 320.0 / Math.Max(frame.PixelWidth, frame.PixelHeight));
        BitmapSource thumb = scale < 1 ? new TransformedBitmap(frame, new ScaleTransform(scale, scale)) : frame;
        var thumbnail = EncodePng(thumb);
        // Canonical RGBA/BGRA pixels pair clipboard and file encodings of the same shot.
        var normalized = new FormatConvertedBitmap(frame, PixelFormats.Bgra32, null, 0);
        var stride = checked(frame.PixelWidth * 4);
        var pixels = new byte[checked(stride * frame.PixelHeight)];
        normalized.CopyPixels(pixels, stride, 0);
        using var digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        digest.AppendData(BitConverter.GetBytes(frame.PixelWidth));
        digest.AppendData(BitConverter.GetBytes(frame.PixelHeight));
        digest.AppendData(pixels);
        return new ClipboardPayload { ImageData = encoded, ThumbnailData = thumbnail, Extension = extension, Title = title, Source = source, CapturedAt = capturedAt, Digest = Convert.ToHexString(digest.GetHashAndReset()) };
    }
    internal static byte[] EncodePng(BitmapSource image)
    {
        if (!CapturePolicy.ValidDimensions(image.PixelWidth, image.PixelHeight)) throw new InvalidDataException("Image exceeds the 50-megapixel limit.");
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(image));
        using var output = new BoundedImageStream();
        encoder.Save(output);
        if (output.Length > CapturePolicy.MaximumImageBytes) throw new InvalidDataException("Image exceeds the 25 MB item limit.");
        return output.ToArray();
    }
    private sealed class BoundedImageStream : MemoryStream
    {
        public override void Write(byte[] buffer, int offset, int count)
        {
            if (Position + count > CapturePolicy.MaximumImageBytes) throw new InvalidDataException("Image exceeds the25 MB encoded limit.");
            base.Write(buffer, offset, count);
        }
        public override void Write(ReadOnlySpan<byte> buffer)
        {
            if (Position + buffer.Length > CapturePolicy.MaximumImageBytes) throw new InvalidDataException("Image exceeds the25 MB encoded limit.");
            base.Write(buffer);
        }
        public override void WriteByte(byte value)
        {
            if (Position >= CapturePolicy.MaximumImageBytes) throw new InvalidDataException("Image exceeds the25 MB encoded limit.");
            base.WriteByte(value);
        }
        public override void SetLength(long value)
        {
            if (value > CapturePolicy.MaximumImageBytes) throw new InvalidDataException("Image exceeds the25 MB encoded limit.");
            base.SetLength(value);
        }
    }
    internal static BitmapSource DecodeForCopy(byte[] encoded)
    {
        if (encoded.Length > CapturePolicy.MaximumImageBytes) throw new InvalidDataException("Image exceeds the item limit.");
        using var input = new MemoryStream(encoded, false);
        var decoder = BitmapDecoder.Create(input, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.None);
        var first = decoder.Frames[0];
        if (!CapturePolicy.ValidDimensions(first.PixelWidth, first.PixelHeight)) throw new InvalidDataException("Image exceeds the pixel limit.");
        var image = new WriteableBitmap(first);
        image.Freeze();
        return image;
    }
}
