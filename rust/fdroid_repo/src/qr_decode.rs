use zxingcpp::{Barcode, BarcodeFormat, ImageFormat, ImageView};

#[derive(Debug)]
pub struct QrDecodeResult {
    pub text: String,
    pub format: String,
    pub points: Vec<f64>,
    pub raw_bytes: Vec<u8>,
    pub symbology_identifier: String,
    pub is_mirrored: bool,
    pub is_inverted: bool,
}

pub fn decode_qr_luma(
    luma: &[u8],
    width: i32,
    height: i32,
) -> Result<Option<QrDecodeResult>, String> {
    if luma.is_empty() || width <= 0 || height <= 0 {
        return Ok(None);
    }
    let expect = (width as usize).checked_mul(height as usize).ok_or("尺寸溢出")?;
    if luma.len() < expect {
        return Err(format!("luma 长度不足: {} < {}", luma.len(), expect));
    }
    let image = ImageView::from_slice(&luma[..expect], width, height, ImageFormat::Lum)
        .map_err(|e| format!("ImageView 构造失败: {e}"))?;

    let reader = zxingcpp::read()
        .try_harder(true)
        .try_rotate(false)
        .try_invert(true)
        .return_errors(true)
        .max_number_of_symbols(1)
        .formats(&[BarcodeFormat::QRCode]);

    let results = reader.from(&image).map_err(|e| format!("解码失败: {e}"))?;

    let mut candidate: Option<QrDecodeResult> = None;
    for b in results {
        if b.is_valid() {
            return Ok(Some(barcode_to_result(&b)));
        }
        if candidate.is_none() && !position_is_degenerate(&b) {
            candidate = Some(candidate_to_result(&b));
        }
    }
    Ok(candidate)
}

fn barcode_to_result(b: &Barcode) -> QrDecodeResult {
    QrDecodeResult {
        text: b.text(),
        format: b.format().to_string(),
        points: points_to_vec(b),
        raw_bytes: b.bytes(),
        symbology_identifier: b.symbology_identifier(),
        is_mirrored: b.is_mirrored(),
        is_inverted: b.is_inverted(),
    }
}

fn candidate_to_result(b: &Barcode) -> QrDecodeResult {
    QrDecodeResult {
        text: String::new(),
        format: String::new(),
        points: points_to_vec(b),
        raw_bytes: Vec::new(),
        symbology_identifier: String::new(),
        is_mirrored: false,
        is_inverted: false,
    }
}

fn points_to_vec(b: &Barcode) -> Vec<f64> {
    let p = b.position();
    vec![
        p.top_left.x as f64,
        p.top_left.y as f64,
        p.top_right.x as f64,
        p.top_right.y as f64,
        p.bottom_right.x as f64,
        p.bottom_right.y as f64,
        p.bottom_left.x as f64,
        p.bottom_left.y as f64,
    ]
}

fn position_is_degenerate(b: &Barcode) -> bool {
    let p = b.position();
    let dx = p.top_left.x - p.bottom_right.x;
    let dy = p.top_left.y - p.bottom_right.y;
    dx == 0 && dy == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_generated_qr() {
        let barcode = zxingcpp::create(BarcodeFormat::QRCode)
            .from_str("hello zxing-cpp")
            .expect("create barcode");
        let img = barcode.to_image().expect("to image");
        assert_eq!(img.format(), ImageFormat::Lum);
        let w = img.width();
        let h = img.height();
        let data = img.data();

        let result = decode_qr_luma(&data, w, h)
            .expect("decode no error")
            .expect("detected");
        assert_eq!(result.text, "hello zxing-cpp");
        assert_eq!(result.format, "QR Code");
        assert_eq!(result.points.len(), 8);
        assert!(result.points.iter().all(|v| *v >= 0.0));
        assert!(!result.raw_bytes.is_empty());
    }

    #[test]
    fn decode_blank_image_returns_none() {
        let (w, h): (i32, i32) = (64, 64);
        let data = vec![255u8; (w * h) as usize];
        assert!(decode_qr_luma(&data, w, h).expect("no error").is_none());
    }

    #[test]
    fn decode_short_luma_returns_err() {
        let err = decode_qr_luma(&[1, 2, 3], 10, 10).expect_err("should err");
        assert!(err.contains("luma 长度不足"));
    }

    #[test]
    fn decode_damaged_qr_returns_position_candidate() {
        let barcode = zxingcpp::create(BarcodeFormat::QRCode)
            .from_str("damage me")
            .expect("create barcode");
        let writer = zxingcpp::write().scale(8);
        let img = barcode.to_image_with(&writer).expect("to image");
        let w = img.width();
        let h = img.height();
        let mut data = img.data();
        // 翻转中部水平带（40%~60%）：定位图形在四角保持完整 → 检测成功、解码失败
        for y in (h * 2 / 5)..(h * 3 / 5) {
            for x in 0..w {
                let i = (y * w + x) as usize;
                data[i] = 255 - data[i];
            }
        }

        let result = decode_qr_luma(&data, w, h)
            .expect("decode no error")
            .expect("should detect at least");
        assert!(!result.points.is_empty());
    }
}
