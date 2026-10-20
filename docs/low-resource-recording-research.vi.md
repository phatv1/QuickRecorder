# Nghiên cứu ghi màn hình tiết kiệm tài nguyên

Ngày: 20/10/2026. Mã nguồn khảo sát: commit `e94488b`, QuickRecorder 1.8.1.

Phạm vi: nghiên cứu mã nguồn và tài liệu kỹ thuật, đề xuất cấu hình và cách kiểm chứng. Cập nhật sau khảo sát: pipeline production đã được triển khai trong fork (xem mục 12 và `docs/FORK.md`). Các bitrate và tiêu chí nghiệm thu bên dưới là điểm bắt đầu thử nghiệm, không phải benchmark trên màn hình làm việc thực tế.

## 1. Hướng đề xuất

Giữ ScreenCaptureKit + AVAssetWriter, bổ sung một profile riêng cho quan sát công việc: **0,5 FPS, cạnh dài tối đa 1920 px, SDR, HEVC hardware, video khoảng 200 kbps và AAC mono 24 kHz/48 kbps liên tục**. So sánh H.264 trên các máy và công cụ phát/AI đích trước khi chọn codec mặc định. Có thể giảm tiếp xuống 0,2 FPS nếu mục tiêu chỉ là thấy các trạng thái công việc kéo dài vài giây.

Theo yêu cầu bổ sung, các giá trị này là preset khởi điểm. Thiết kế cần mở cho người dùng tự thử độ phân giải, FPS và bitrate thấp hơn, cũng như kích thước đầu ra khác màn hình; chi tiết ở mục 11.

Ưu tiên giữ chữ đủ đọc, giảm số hình theo thời gian trước, rồi giảm bitrate và độ phân giải theo kết quả đánh giá. Video mờ làm mất chữ ở mọi frame; FPS thấp giữ được ảnh rõ của những thời điểm đã lấy mẫu nhưng bỏ lỡ thao tác giữa hai ảnh. Đây là lựa chọn kỹ thuật cho yêu cầu hiện tại, không phải ngưỡng chất lượng đã được chứng minh.

Apple cung cấp `minimumFrameInterval` để giới hạn tần suất cập nhật hình. Giá trị là khoảng thời gian, không phải FPS nguyên; vì vậy 0,5 FPS tương ứng 2 giây và 0,2 FPS tương ứng 5 giây. Đây là giới hạn tốc độ cập nhật, không bảo đảm có đúng số frame đó khi màn hình tĩnh. [Apple: minimumFrameInterval](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/minimumframeinterval).

Audio không cần “FPS” giống hình. Cấu hình audio bằng sample rate, số kênh và bitrate; audio có callback/track riêng và dùng chung timeline với video. Ví dụ: hình cập nhật mỗi 5 giây, audio vẫn lấy 24.000 mẫu/giây. Không tăng tốc hay kéo chậm playback để tạo FPS thấp.

## 2. Những giới hạn tìm thấy trong project

Các vị trí dưới đây dựa trên commit khảo sát; các rủi ro timing là kết luận từ code, chưa tái hiện bằng ghi màn hình thực tế.

| Điểm hiện tại | Bằng chứng | Hệ quả và thay đổi cần thiết |
|---|---|---|
| FPS lưu bằng `Int`; UI thấp nhất 10 FPS | `QuickRecorderApp.swift:158`; `ViewModel/AppSelector.swift:206,234`; `Supports/AppleScript.swift:208`; `Supports/Scriptable.sdef:45` | Đổi toàn bộ đường cấu hình sang số thực hoặc khoảng thời gian; migrate setting số nguyên cũ. Chỉ sửa picker chưa đủ. |
| Interval dùng FPS làm `CMTimeScale`; FPS >=60 đi vào nhánh timescale 0 | `RecordEngine.swift:227` | Không thể dùng cách cast này cho FPS <1. Dùng reciprocal interval hợp lệ; biểu diễn chế độ không giới hạn bằng giá trị API hỗ trợ rõ ràng. |
| Resolution chỉ Retina 2x hoặc Normal 1x | `ViewModel/AppSelector.swift:227`; `RecordEngine.swift:170,189,250` | Thêm giới hạn cạnh dài/kích thước pixel, giữ tỉ lệ và kích thước chẵn. Áp dụng sau khi tính vùng crop và trước khi tạo stream. |
| Bitrate suy ra từ resolution × FPS, chặn tối thiểu 200 kbps | `RecordEngine.swift:387–411` | Thêm bitrate độc lập. Profile cực thấp không nên dùng nguyên công thức cho video 60 FPS. Floor 200 kbps là budget 90 MB/giờ, không phải dung lượng thực tối thiểu. |
| Audio mặc định 256 kbps, stereo, capture 48 kHz | `QuickRecorderApp.swift:233,685`; `SCContext.swift:222`; `RecordEngine.swift:222` | Audio có thể lớn hơn video khi FPS rất thấp. Bổ sung mono, 24/48 kHz, 32/48/64 kbps. |
| Writer session mở theo frame video đầu; audio chờ `lastPTS`/`startTime` | `RecordEngine.swift:478,492,608,655,735` | Tách khởi động audio khỏi frame hình đầu để không bỏ âm đầu phiên. |
| Pause offset chỉ được áp dụng cho sample video | `RecordEngine.swift:587–614`; audio append ở `482,496,656,739` | Có nguy cơ lệch hình/tiếng. Áp dụng một normalized timeline cho mọi track. Không đo pause bằng last video PTS. |
| Mic bỏ qua timestamp từ tap, tạo PTS bằng host-clock “now” mỗi callback | `RecordEngine.swift:491,793` | Dùng timestamp thu thật hoặc sample counter gắn với clock anchor; mute phải giữ PTS/duration nguồn. |
| H.264 có hardware probe riêng, writer thật không yêu cầu hardware; HEVC không có probe tương tự | `RecordEngine.swift:261–285,403–423` | Không kết luận writer hiện đang chạy software. Cần kiểm chứng lựa chọn encoder thật và quy định fallback. |
| SDR xuất BGRA; HDR mới đặt queueDepth=8 | `RecordEngine.swift:202,215` | Thử NV12 cho profile SDR; SDR hiện dùng queue mặc định, không phải 8. |
| Screen/audio callback dùng global queue và cùng sửa state | `RecordEngine.swift:290–291,608–656` | Serialize state/writer; không để audio và video đua nhau mở/đóng session. |
| Rơi audio khi input chưa ready, không kiểm tra kết quả append | `RecordEngine.swift:480,494,656,737` | Thêm thống kê drop/error, bounded queues và chính sách overload. |
| Stop chưa đợi capture/tap drain rồi mới finish | `SCContext.swift:383–408` | Dễ mất audio đuôi hoặc đua với append; cần state machine stop. |
| Giữ full first frame đến hết phiên kể cả preview tắt | `RecordEngine.swift:639`; `SCContext.swift:528` | Không retain khi không cần; nếu cần preview, copy thumbnail nhỏ rồi thả surface. |
| Mic + system có thể encode riêng rồi export mix/remux | `SCContext.swift:786–909` | Tăng I/O, CPU và dung lượng tạm; cân nhắc mix PCM realtime thành một AAC track. |

Mặc định đăng ký lần đầu là H.264, 60 FPS, Retina 2x, chất lượng High (`QuickRecorderApp.swift:230–245`). Setting đã lưu của từng người dùng có thể khác. `CIContext`/`NSImage` không nằm trong đường encode mọi frame thông thường; không có bằng chứng đó là nút thắt CPU chính.

## 3. Preset nên thử

Tất cả preset dùng SDR 8-bit, bỏ alpha/HDR/camera/presenter overlay/magnifier; giữ cursor nếu cần nhận biết vị trí thao tác. Kích thước là **cạnh dài tối đa**, giữ nguyên tỉ lệ, không upscale. Chữ nhỏ trên màn hình nhiều nội dung có thể cần giữ resolution lớn hơn.

| Preset thử nghiệm | Video | Video target | Một track audio liên tục | Budget MB/giờ | Budget GB/8 giờ |
|---|---|---:|---|---:|---:|
| Quan sát trạng thái | 0,2 FPS; cạnh dài 1600 | 80 kbps | AAC mono 24 kHz, 32 kbps | 50,4 | 0,403 |
| Khởi điểm đề xuất | 0,5 FPS; cạnh dài 1920 | 200 kbps | AAC mono 24 kHz, 48 kbps | 111,6 | 0,893 |
| Dễ theo dõi hơn | 1 FPS; cạnh dài 1920 | 350 kbps | AAC mono 48 kHz, 64 kbps | 186,3 | 1,490 |

Đây là ngân sách tính toán, chưa tính container, metadata, snapshot bổ sung, retry và file tạm. Encoder có thể dùng ít hơn hoặc vượt target theo nội dung; target average bitrate không phải hard cap. [Apple: AverageBitRate](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_averagebitrate).

```text
MB/giờ = (video_kbps + tổng_audio_kbps) × 0,45
GB/8 giờ = MB/giờ × 8 / 1000
```

Đơn vị thập phân: 1 MB = 1.000.000 byte. Với hai audio track, cộng cả hai bitrate. Riêng 256 kbps tương đương 115,2 MB/giờ/track; 48 kbps tương đương 21,6 MB/giờ/track. Không so sánh trực tiếp các budget này với dung lượng baseline thực tế khi chưa đo cùng workload.

ScreenCaptureKit hỗ trợ audio 8/16/24/48 kHz và 1 hoặc 2 kênh. Đề xuất 24 kHz mono/32–48 kbps cho giọng nói phải được nghe và kiểm tra ASR; âm nhạc, nhiều người nói chồng nhau hoặc âm hệ thống có thể cần 48 kHz/64 kbps hoặc stereo. [Apple: sampleRate](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/samplerate), [channelCount](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/channelcount).

Đổi `AVSampleRateKey` không thay thế việc resample/downmix nguồn mic đúng cách. Đảm bảo capture format, converter, timestamp và encoder đồng nhất; chỉ bật AEC khi cần xử lý tiếng loa lọt vào mic. Giữ multitrack như tùy chọn nếu cần tách người nói/nguồn âm cho AI; khi ấy phải chấp nhận budget tăng.

## 4. Tối ưu CPU và RAM

**Giảm công việc ở nguồn.** Đặt interval và output size trong ScreenCaptureKit; capture 60 FPS rồi bỏ 59 frame vẫn phải trả phần chi phí upstream. Apple mô tả ScreenCaptureKit có hardware scaling/conversion và GPU-backed buffers. Vì thế nên dùng khả năng này trước khi thêm resize/ảnh trung gian trên CPU. [Apple WWDC22: Take ScreenCaptureKit to the next level](https://developer.apple.com/videos/play/wwdc2022/10155/).

**Dùng encoder hardware thực tế.** Ưu tiên thử HEVC trên Apple Silicon, so sánh H.264 cho Intel và khả năng decode downstream. Không cam kết HEVC luôn ít CPU/điện hơn. `AVVideoEncoderSpecificationKey` nằm ở cấp ngoài của video settings và nhận dictionary VideoToolbox; có thể yêu cầu hardware, xử lý thất bại bằng giảm resolution hoặc codec phù hợp. Probe riêng không bảo đảm writer sau đó dùng cùng encoder. [Apple: AVVideoEncoderSpecificationKey](https://developer.apple.com/documentation/avfoundation/avvideoencoderspecificationkey), [RequireHardwareAcceleratedVideoEncoder](https://developer.apple.com/documentation/videotoolbox/kvtvideoencoderspecification_requirehardwareacceleratedvideoencoder).

Nếu dùng trực tiếp `VTCompressionSession`, query `UsingHardwareAcceleratedVideoEncoder` trên chính session encode. AVAssetWriter không trực tiếp đưa session nội bộ ra để query bằng cách đó. Không cần viết lại toàn bộ encoder chỉ để thêm FPS thấp. [Apple: UsingHardwareAcceleratedVideoEncoder](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_usinghardwareacceleratedvideoencoder).

**Giới hạn hàng đợi và surface.** Bắt đầu với queueDepth mặc định 3 trong profile SDR, đo stall/drop rồi mới tăng nếu cần. Apple cho biết queue sâu hơn dùng nhiều bộ nhớ và khuyến cáo không vượt 8. Audio có bounded queue ngắn; video có thể bỏ frame cũ khi quá tải. Không dùng queue vô hạn để che vấn đề writer chưa ready. [Apple: queueDepth](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/queuedepth).

Ước tính ảnh thô, chưa tính alignment/pool/encoder/WindowServer:

| Một surface | BGRA, 4 byte/pixel | NV12 4:2:0, xấp xỉ 1,5 byte/pixel |
|---|---:|---:|
| 3840 × 2160 | 31,64 MiB | 11,87 MiB |
| 1920 × 1080 | 7,91 MiB | 2,97 MiB |

Giảm cả hai chiều một nửa giảm số pixel 4 lần. Đổi BGRA sang NV12 giảm footprint danh nghĩa khoảng 62,5% mỗi surface. **Các tỷ lệ này không phải mức giảm tổng RAM app.** Giảm FPS chủ yếu giảm số lần xử lý, không tự giảm kích thước mỗi surface hay số buffer giữ trong pool.

Thử NV12 bằng A/B với BGRA: kiểm tra chữ màu nhỏ, nền tối, đường viền và OCR. BGRA đầu vào cũng không bảo đảm file H.264/HEVC giữ màu 4:4:4; cần xem format đầu ra thực. Không chuyển sang screenshot JPEG định kỳ chỉ vì nghĩ FPS thấp thì screenshot luôn rẻ hơn video; interframe compression có thể có lợi cho màn hình gần như đứng yên.

Chỉ đăng ký mouse monitor khi cần overlay/magnifier hoặc tín hiệu cho adaptive capture. Tắt preview sau phiên không giảm encode hiện tại nhưng có thể bỏ việc giữ first-frame full size. Không chạy OCR/AI trên mọi frame tại máy nhân viên khi mục tiêu là CPU tối thiểu; xử lý theo batch/ở hệ thống đánh giá, hoặc lấy ảnh rõ tại mốc có ý nghĩa.

## 5. Timeline đúng cho audio liên tục và hình rất thưa

```text
                       chung epoch + pause offset
ScreenCaptureKit hình ─┐
                       ├─ RecordingCoordinator ─ video track thưa ─┐
System audio + mic ────┘                        └ audio liên tục ───┴ MP4
```

1. Coordinator sở hữu trạng thái, epoch clock, pause intervals và writer; mọi thay đổi được serialize. Audio không chờ `last video PTS`. Chọn epoch từ timestamp capture hợp lệ và bảo đảm ảnh mở đầu hiển thị đúng mốc; có thể buffer giới hạn khi chờ ảnh đầu.
2. Với mic, dùng `AVAudioTime.hostTime`/sample time hoặc sample counter có clock anchor. Không timestamp bằng thời điểm callback được CPU thực thi. `AVAudioTime` hỗ trợ host time và sample time. [Apple: AVAudioTime](https://developer.apple.com/documentation/avfaudio/avaudiotime).
3. Cùng một quy tắc `normalizedPTS = sourcePTS - epoch - accumulatedPause` áp dụng cho video, system audio và mic. Đo pause bằng clock, không bằng khoảng cách tới frame hình trước. Nếu muốn hình tạm dừng nhưng audio vẫn chạy thì đó là chế độ khác: chỉ ngừng cập nhật hình và giữ timeline/audio; không dùng global pause hiện tại.
4. Mute zero PCM nhưng giữ nguyên timestamp và số mẫu. Audio continuity không được phụ thuộc frame hình có thay đổi hay không.
5. Video giữ source PTS thực, không đánh lại số frame thành chuỗi 30/60 FPS. `AVVideoExpectedSourceFrameRateKey` chỉ là hint cho encoder, không điều khiển cadence. [Apple: ExpectedSourceFrameRate](https://developer.apple.com/documentation/avfoundation/avvideoexpectedsourceframeratekey).
6. Stop theo thứ tự: ngừng producers → đợi callbacks/tap drain → hoàn tất dữ liệu đang chờ → chốt end PTS → finish inputs/writer. Theo dõi `append` result, writer status/error, audio drops và video drops.
7. Giữ hình cuối đến end PTS bằng sample duration/terminal held frame thích hợp, chốt session và xác minh file. Chỉ thấy audio/container đủ thời lượng chưa chứng minh video track không kết thúc sớm. Không gọi `endSession` thì writer tự chốt dựa trên sample cuối; không mặc định `endSession` đơn lẻ sẽ sửa mọi trường hợp duration của sparse-video track. [Apple: endSession](https://developer.apple.com/documentation/avfoundation/avassetwriter/endsession(atsourcetime:)).

Ví dụ cấu hình cần thiết, chưa phải patch hoàn chỉnh:

```swift
// fps đã được validate finite, > 0 và nằm trong phạm vi cấu hình hỗ trợ.
let interval = CMTime(seconds: 1.0 / fps, preferredTimescale: 600_000)
configuration.minimumFrameInterval = interval
configuration.sampleRate = 24_000
configuration.channelCount = 1
// audio writer/converter được cấu hình riêng cho AAC 48_000 bit/s.
```

Thử GOP tối đa theo **giây**, chẳng hạn 10–30 giây, thay vì mặc định dùng 60 frame. Ở 0,2 FPS, 60 frame cách nhau tới 300 giây; ngược lại GOP 2 giây có thể khiến gần như mọi frame thành keyframe. Chọn lại theo dung lượng, seek và cách cắt segment thực tế. [Apple: MaxKeyFrameIntervalDuration](https://developer.apple.com/documentation/avfoundation/avvideomaxkeyframeintervaldurationkey).

## 6. Ghi nhiều giờ và phương án nâng cao

Project có lịch sử fragmented MP4 + audio bị stall, được mô tả trong `CLAUDE.md` và `RecordEngine.swift:443–461`. Đây là hành vi đã được ghi nhận của pipeline dự án, không phải kết luận rằng mọi AVAssetWriter đều không hỗ trợ audio fragment. Không mở lại fragmentation đại trà khi thêm profile mới; giữ phạm vi đang hoạt động và kiểm chứng riêng cấu hình mới. Input audio hiện còn được thêm khi setting audio tắt, nên cần sửa cách xác định input thực trước khi dựa vào điều kiện đó.

Thử segment 5–15 phút, finalize từng segment, có manifest thời gian và keyframe đầu segment. Mục đích là giảm phạm vi file đang mở và dữ liệu có thể mất khi crash, không phải làm bitrate thấp hơn. Segment đang ghi vẫn có thể hỏng. Rollover phải giữ audio liên tục, không chờ keyframe quá lâu và không export trộn lại toàn bộ ca làm sau mỗi lần cắt.

Nếu mux hình rất thưa và audio liên tục gặp backpressure trên thiết bị đích, thử hai writer riêng cho video/audio chung epoch + manifest; mux khi cần export. Phương án này làm phát lại/tích hợp phức tạp hơn nên chỉ áp dụng khi có bằng chứng cần thiết. Chuỗi ảnh + audio cũng phù hợp với AI nếu hệ thống đọc trực tiếp timeline ảnh, nhưng cần player riêng và phải đo storage; không mặc định tiết kiệm hơn HEVC.

Sau khi preset cố định ổn định, có thể thử adaptive sampling: 0,1–0,2 FPS khi tĩnh, 0,5–1 FPS bình thường, burst 2–5 FPS khi chuyển ứng dụng/scroll. Dùng tín hiệu nhẹ, debounce/hysteresis, chỉ thay cadence, tránh đổi resolution liên tục. Apple cho phép update cấu hình khi stream đang chạy và cung cấp dirty rect metadata; full-frame diff trên CPU có thể tốn hơn phần tiết kiệm. [Apple WWDC22](https://developer.apple.com/videos/play/wwdc2022/10155/).

Adaptive không khôi phục được thao tác đã xảy ra giữa hai frame. Với chu kỳ 5 giây và trạng thái tồn tại 1 giây, xác suất lấy trúng chỉ khoảng 20% nếu pha xuất hiện phân bố đều; đây là phép tính lấy mẫu, không phải số benchmark. Nếu cần hiểu các bước thao tác ngắn, tăng FPS hoặc bổ sung mốc sự kiện, rồi đánh giá đúng nhu cầu đó.

## 7. Định nghĩa “nhìn thấy được” cho người và AI

Không dùng một nhãn Low/Medium/High để thay thế tiêu chí chất lượng. Cần tách các tác vụ:

| Nhu cầu | Cách chấm |
|---|---|
| Biết đang dùng ứng dụng/tác vụ nào | Người/AI xác định đúng app, màn hình, loại công việc ở các mốc đã gán nhãn |
| Đọc được nội dung | Đọc tiêu đề, đoạn chữ, ô bảng tính và terminal ở kích thước phát 100%; chấm đúng ký tự/nội dung |
| OCR | CER/WER trên vùng chữ có ground truth, gồm tiếng Việt, chữ nhỏ, dark mode và màu |
| AI hiểu luồng công việc | Bộ câu hỏi cố định về trạng thái/chuyển bước, chấm độ đúng và số bước bị bỏ lỡ |
| Nghe và nhận dạng lời nói | Nghe đối chiếu, ASR WER trên audio sạch có transcript và tiếng Việt; kiểm tra đầu/đuôi, gaps và A/V drift |

Đánh giá riêng mất chi tiết do nén/scale và mất sự kiện do lấy mẫu thưa. So OCR trên frame cùng timestamp cho chất lượng không gian; so tỷ lệ bắt được trạng thái/sự kiện trên toàn timeline cho chất lượng thời gian. Cố định model, phiên bản, prompt và cách lấy frame của AI trong các vòng A/B. Downstream tự lấy 1 frame/giây không thể tạo thêm thông tin từ video 0,2 FPS.

Ngưỡng nghiệm thu khởi điểm có thể là: nhận diện app/tác vụ ≥95%; OCR CER/WER tăng không quá 5 điểm phần trăm so với ảnh tham chiếu ở những vùng cần đọc; ASR WER tăng không quá 3 điểm phần trăm; không rơi audio, không drift tăng dần. Các ngưỡng này cần chủ sản phẩm chốt theo tác vụ, không phải tiêu chuẩn của Apple hay kết quả nghiên cứu thực nghiệm ở đây. PSNR/SSIM có thể hỗ trợ chẩn đoán nhưng không thay thế việc đọc chữ và hiểu thao tác.

## 8. Kế hoạch đo và triển khai

**Bước 1 — Baseline.** Ghi lại setting thực và phần cứng/OS; chạy workload lặp lại 10–15 phút gồm tài liệu, spreadsheet, browser, terminal/IDE, scroll, màn hình tĩnh và cuộc gọi. Lặp ≥3 lần cùng nội dung. Không tuyên bố giảm CPU/RAM theo tỷ lệ FPS khi chưa đo.

**Bước 2 — Đúng timeline.** Thử 0,1/0,2/0,5/1 FPS với system/mic/both; nói ngay khi Start; tĩnh vài phút; pause/resume nhiều lần; mute/unmute; stop giữa hai frame và trước frame kế tiếp; ngủ/thức, lock/unlock, đổi màn hình/thiết bị audio. Kiểm tra âm đầu/cuối và duration từng track, không chỉ format.duration.

**Bước 3 — Tối ưu có đối chứng.** Tách từng biến: cadence → output size → bitrate/audio → codec/hardware → BGRA/NV12 → queue/thumbnail → adaptive. Dùng các preset ở mục 3 làm điểm đầu, không chạy toàn bộ tích Descartes mọi cấu hình. Sau thử ngắn, soak test 2–8 giờ với profile thắng và các nhóm máy đại diện.

**Bước 4 — Thu chỉ số.** CPU app và WindowServer theo một định nghĩa nhất quán; physical footprint/peak và chiều hướng tăng RAM; energy/thermal khi cần; file MB/giờ thực; dung lượng tạm cực đại; audio/video drops; append failures; chênh duration; sai số beep/flash dùng đánh dấu A/V. CPU thấp hơn nhưng chuyển hết chi phí sang WindowServer/GPU chưa chứng minh tổng tài nguyên tốt hơn.

**Bước 5 — Kiểm tra downstream.** QuickTime, browser/player thực tế, seek gần cuối file, segment rollover và pipeline AI. Giữ frame timestamps khi extract; không ép CFR 30 FPS chỉ để công cụ đọc dễ hơn. Nếu AI yêu cầu định dạng riêng, tạo bản dẫn xuất khi xử lý.

Ví dụ lệnh kiểm tra, dựa trên [tài liệu ffprobe](https://ffmpeg.org/ffprobe.html):

```sh
ffprobe -v error -show_format -show_streams -of json recording.mp4
ffprobe -v error -select_streams v:0 -show_packets \
  -show_entries packet=pts_time,dts_time,duration_time,size,flags \
  -of csv=p=0 recording.mp4
ffprobe -v error -select_streams a:0 -show_packets \
  -show_entries packet=pts_time,duration_time,size \
  -of csv=p=0 recording.mp4
ffmpeg -v error -i recording.mp4 -f null -
```

Đọc PTS/duration của packet/frame thực; không chỉ dựa vào `r_frame_rate` hay `avg_frame_rate` để kết luận cadence nguồn VFR. Với B-frame, packet PTS có thể đảo theo thứ tự decode: kiểm DTS và decoded-frame PTS, không yêu cầu packet PTS luôn tăng. Audio codec delay/padding có thể tạo sai khác nhỏ cần phân biệt với mất dữ liệu; audio packet đều cũng chưa chứng minh không có im lặng nhân tạo.

**Thứ tự làm code:** setting `Double` và migration/UI/AppleScript → coordinator/timeline/audio settings → profile riêng opt-in, custom resolution/bitrate → hardware/buffer/queues → segment → adaptive. Giữ profile hiện tại để đối chứng và tránh đổi hành vi mặc định đang hoạt động tốt.

## 9. Smoke test đã thực hiện

Đã chạy AVAssetWriter offline trên macOS 14.8.4 arm64, yêu cầu hardware encoder trong writer thật; 1280×720, video target 150 kbps; AAC mono 24 kHz/32 kbps; 16 giây. Dữ liệu gồm hình chữ tổng hợp và tone 440 Hz, không thu màn hình/microphone. Test dùng sample duration tường minh, `endSession(16s)`, `expectsMediaDataInRealTime=false` và không bật fragmentation.

| Codec | Cadence gửi vào | Số video frame | Duration video/audio track | Audio giải mã | Decode toàn file |
|---|---|---:|---|---|---|
| H.264 | 0,2 FPS, PTS 0/5/10/15s | 4 | 16s / 16s | 384.000 mẫu = 16s | Thành công |
| H.264 | 0,5 FPS, PTS 0/2/…/14s | 8 | 16s / 16s | 384.000 mẫu = 16s | Thành công |
| HEVC | 0,2 FPS, PTS 0/5/10/15s | 4 | 16s / 16s | 384.000 mẫu = 16s | Thành công |
| HEVC | 0,5 FPS, PTS 0/2/…/14s | 8 | 16s / 16s | 384.000 mẫu = 16s | Thành công |

Kết quả xác nhận writer/container hỗ trợ hình thưa và audio liên tục trên máy này. Chưa kiểm chứng đường realtime ScreenCaptureKit/AVAudioEngine của app. HEVC 0,2 FPS có frame cuối báo duration kéo tới 20s dù track/container được trim về 16s; cần xem tail và seek bằng player đích. H.264 case 0,2 FPS báo average frame rate 0,25 vì có 4 frame trên phiên 16s, cho thấy chỉ số average không thay thế việc kiểm interval. Không dùng dung lượng file chữ gần tĩnh để dự đoán ca làm thực.

Script tái lập: [smoke.swift](experiments/lowfps-writer/smoke.swift). Dữ liệu kiểm tra: [results.json](experiments/lowfps-writer/results.json). Chạy từ thư mục project:

```sh
swift docs/experiments/lowfps-writer/smoke.swift
```

Script tạo/thay thế bốn MP4 cùng tên trong `/tmp/qr-lowfps-smoke`. Dùng các lệnh ffprobe/ffmpeg ở mục 8 để kiểm tra lần chạy mới; `results.json` lưu kết quả lần khảo sát này, không tự cập nhật khi chạy script.

## 10. Giới hạn của kết quả nghiên cứu

Chưa benchmark ScreenCaptureKit trên ca làm thực tế, chưa đo CPU/RAM hay OCR/ASR cho các preset đề xuất. Máy khảo sát là macOS 14.8.4 arm64, có Swift Command Line Tools và ffmpeg/ffprobe; `xcode-select` hiện trỏ vào CommandLineTools nên chưa build đầy đủ app bằng Xcode. System audio trong code hiện yêu cầu macOS 13+; cần kiểm thử các nhánh OS còn hỗ trợ trước khi phát hành.

Smoke test synthetic ở mục 9 chỉ chứng minh hành vi writer/container với dữ liệu tạo sẵn; không chứng minh hiệu năng capture, tính liên tục audio thật, chất lượng chữ hay độ ổn định production.

## 11. Tùy chỉnh mở và định dạng chất lượng rất thấp

Yêu cầu bổ sung: cho người dùng chủ động lựa chọn chất lượng chấp nhận được, gồm độ phân giải thấp và độ phân giải đầu ra khác màn hình. Nên triển khai preset + mục Custom, không dùng các preset nghiên cứu làm giới hạn bắt buộc.

| Nhóm cấu hình | Thiết kế đề xuất |
|---|---|
| Độ phân giải | Original; scale theo phần trăm/cạnh dài; preset chiều cao 144/240/360/480/540/720/1080p; custom width × height bằng pixel. Preset theo chiều cao giữ aspect nguồn, không mặc định mọi màn hình là 16:9. |
| Tỉ lệ khung hình | Khóa aspect mặc định; custom canvas có Fit/Fill/Stretch. Fit giữ đủ nội dung, có viền nếu cần; Fill crop phần thừa; Stretch thay đổi hình dạng chữ. Hiển thị preview đúng kết quả. |
| FPS | Các mốc 0,05/0,1/0,2/0,5/1/2/5 và các mức hiện tại, cộng ô nhập số thực hoặc “mỗi N giây một hình”. Mức cực thấp như 0,01 FPS biểu diễn được bằng interval nhưng phải kiểm chứng trên pipeline capture thực trước khi công bố hỗ trợ. |
| Video bitrate | Auto theo preset hoặc nhập target độc lập, gồm thử các mốc 16/32/64/128/256 kbps và cao hơn. Đây là giá trị yêu cầu để thử, không bảo đảm mọi encoder chấp nhận hoặc đạt đúng tốc độ đó. |
| Audio | Bật/tắt từng nguồn; mono/stereo; sample rate; bitrate độc lập. Mở mức thấp theo từng codec và format thực sự hỗ trợ, không giữ giới hạn UI tối thiểu 128 kbps hiện tại. |
| Container và codec | Trình bày riêng file MP4/MOV, video H.264/HEVC và codec audio. Thêm container/codec mới theo backend có thực và ma trận tương thích đã kiểm thử. Đổi đuôi file không tạo ra hỗ trợ format mới. |

Ví dụ màn hình 2560×1600 có thể ghi thành 1280×800 để giữ tỉ lệ; cũng có thể xuất canvas 1280×720 với Fit có viền hoặc Fill crop. Việc đổi output resolution độc lập không yêu cầu đổi resolution màn hình đang dùng. Tính source crop trước, sau đó tính output canvas/content rect và cấu hình kích thước capture để tránh resize lớn trên CPU.

Không mặc định phóng lớn nguồn nhỏ, nhưng có thể cho người dùng chủ động bật upscale nếu cần kích thước file đầu ra cố định. Cấu hình nội bộ lưu rõ requested size và effective size; round theo alignment codec khi cần và hiển thị kết quả thực. Không âm thầm đổi codec, resolution hay bitrate của profile người dùng.

ScreenCaptureKit có API cho scale/output rect, nhưng hành vi phụ thuộc kiểu capture: `scalesToFit` dùng trong independent-window capture; `destinationRect` không được dùng cho single-window capture. Vì vậy cần kiểm thử và xử lý Fit/Fill/Stretch theo từng loại nguồn, không giả định một property sẽ thực hiện mọi chế độ trên mọi nguồn. [Apple: scalesToFit](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/scalestofit), [destinationRect](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/destinationrect).

Chỉ chặn dữ liệu không hợp lệ hoặc tổ hợp kỹ thuật không hỗ trợ: số không hữu hạn, FPS/bitrate/kích thước không dương, dimension/alignment vượt khả năng encoder, codec không phù hợp container. Chất lượng rất thấp là lựa chọn của người dùng; mô tả ngắn như “phù hợp xem bố cục, chữ nhỏ có thể khó đọc” và cho ghi thử, không đặt thêm bước xác nhận mỗi lần chọn.

Backend dùng `canApply(outputSettings:forMediaType:)`, `canAdd`, kết quả khởi tạo/start/append và lỗi thực tế để kiểm tra tổ hợp. `canApply` kiểm tính tương thích với output format; riêng bước đó chưa chứng minh hardware encoder có sẵn, hỗ trợ FPS rất thấp hay phiên ghi dài ổn định. [Apple: canApply](https://developer.apple.com/documentation/avfoundation/avassetwriter/canapply(outputsettings:formediatype:)).

Nên có chức năng ghi thử và phát lại đúng kích thước, hiển thị setting thực, bitrate/dung lượng đo được, thời lượng audio/video, đồng thời lưu profile có tên. Bài thử phải đủ dài để có nhiều lần cập nhật ở cadence đã chọn; clip 10 giây không thể kiểm chứng cadence một hình mỗi 100 giây. Dự toán MB/giờ phải ghi là dự toán; đo clip ngắn không thay cho soak test CPU/RAM và ổn định nhiều giờ.

## 12. Kiểm kê phương pháp giảm dung lượng và phần còn thiếu

Chưa thể gọi là hỗ trợ đầy đủ. Tại thời điểm khảo sát, app production chưa được thay đổi; mục 1–11 là nghiên cứu/đặc tả, ngoại trừ các tính năng đã có sẵn được ghi rõ bên dưới. Cột "App hiện tại" trong bảng phản ánh lúc khảo sát.

**Cập nhật triển khai (fork):** đã thêm `RecordingOptions`, `RecordingSession`, `RecordingVideoProcessor`, `RecordingAdaptiveCapture`, `RecordingTrial`, `VideoCompression` cùng UI tương ứng. Các script trong `verification/` đều PASS bằng Command Line Tools: pipeline (baseline/peak/vbr/hardware × hvc1/avc1), resource, và compression (6 case + cancel/invalid/SHA256). Đã sửa lỗi frame tĩnh cuối bị rơi: frame cuối phải đặt trước điểm kết thúc ≥ 1/600 s (`recordingTerminalFrameLead`) vì timescale video của AVAssetWriter là 600. **Chưa làm:** đo trên máy thật (CPU/RAM, soak test nhiều giờ, MB/giờ thực tế) theo các bước nghiệm thu ở trên.

| Phương pháp | App hiện tại | Phần cần bổ sung |
|---|---|---|
| H.264/HEVC, MP4/MOV | Có lựa chọn | Ma trận hardware/OS/player và quyết định codec theo kết quả đo |
| Hạ chất lượng/bitrate | Có Low/Medium/High điều chỉnh công thức average bitrate | Target bitrate nhập riêng, mode quality, giới hạn peak/budget nếu backend hỗ trợ |
| Hạ FPS | Có FPS nguyên; picker từ 10 FPS | FPS thập phân, interval và thời lượng cuối đúng |
| Hạ resolution | Có Retina/Normal | Custom size/scale, mức rất thấp và Fit/Fill |
| Giảm vùng dữ liệu ghi | Có area/window/app filter | Hướng dẫn chọn vùng cần thiết, output crop phù hợp và budget từng màn hình nếu mở rộng đa màn hình |
| Giảm frame thừa | Giữ source PTS và chỉ lấy frame `.complete` | Dedupe nội dung rõ ràng, dirty-rect-first và adaptive cadence đã đo hiệu quả |
| GOP/B-frame/interframe | Để encoder chọn theo cấu hình mặc định | Tùy chọn kiểm chứng GOP theo giây, reorder và tradeoff seek/latency |
| Audio lossy và bitrate | Có codec audio, bitrate UI từ 128 kbps | Mono, bitrate thấp, sample rate độc lập, kiểm thử VBR theo codec |
| Giảm số audio track | Có chọn nguồn, lưu nhiều track rồi có thể post-mix | Một track mix PCM realtime nếu phù hợp; tính tổng bitrate mọi track |
| Bỏ HDR/alpha/overlay | Có tùy chọn liên quan | Profile tiết kiệm kết hợp và xác minh format file thực |
| Nén lại sau ghi | Chưa có một tính năng nén giảm size chuyên biệt trong phần code đã khảo sát | Export/re-encode tùy chọn, xác minh chất lượng và file đích trước khi xử lý bản gốc |
| Ngân sách lưu trữ | Chưa có điều khiển theo MB/giờ trong pipeline khảo sát | Tính budget tổng, dự toán/đo thực, điều chỉnh trong các giới hạn chất lượng người dùng chọn |
| Quản lý file dài hạn | Chưa khảo sát toàn hệ thống doanh nghiệp | Chính sách archive/retention/quota riêng; giảm tổng dữ liệu lưu, không đổi hiệu suất codec |

### 12.1. Bitrate, quality và ngân sách dung lượng

Với cùng thời lượng, size media xấp xỉ tích phân **bitrate thực của tất cả track theo thời gian**, cộng overhead. Hạ FPS, resolution hoặc sample rate giúp giảm dữ liệu nguồn/chi phí xử lý và có thể cho phép hạ bitrate mà vẫn đủ chất lượng. Nếu bitrate thực được giữ cố định thì các thao tác đó không tự làm file nhỏ theo cùng tỷ lệ. Tương tự, chuyển stereo sang mono nhưng vẫn encode đúng cùng bitrate không tự giảm một nửa file.

UI nên phân biệt: (a) target average bitrate để định ngân sách; (b) quality-based encoding để nội dung tĩnh được dùng ít bit và cảnh phức tạp có thể dùng nhiều hơn; (c) peak/window rate limit khi có yêu cầu giới hạn dữ liệu. Quality-based encoding không bảo đảm dung lượng cố định. CBR không phải lựa chọn mặc định tối ưu dung lượng cho màn hình thường tĩnh.

`videoQuality` hiện tại chỉ làm thay đổi công thức bitrate trong `RecordEngine.swift:387–411`; chưa phải CRF/CQ/QP. `kVTCompressionPropertyKey_Quality` không tương đương CRF của x264/x265; mức hỗ trợ và ý nghĩa phụ thuộc encoder. Không gắn nhãn “CRF” nếu backend không cung cấp đúng chế độ đó. [Apple: Quality](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_quality).

VideoToolbox có `DataRateLimits` theo số byte trong cửa sổ thời gian, nhưng tài liệu lưu ý một số codec không hỗ trợ giới hạn đó. Nếu dùng VT session trực tiếp, query supported properties trên chính session; AVAssetWriter phải dùng cơ chế cấu hình được hỗ trợ và thử ghi, không mặc định mọi VT key đều có thể truyền vào writer. [Apple: DataRateLimits](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_dataratelimits), [SupportedPropertyDictionary](https://developer.apple.com/documentation/videotoolbox/vtsessioncopysupportedpropertydictionary(_:supportedpropertydictionaryout:)).

Có thể thêm mục tiêu “MB/giờ” hoặc “GB/ca”: trừ budget audio và overhead trước khi suy ra budget video. Ví dụ 1 GB/8 giờ tương đương khoảng 277,8 kbps tổng; một audio track 48 kbps để lại khoảng 229,8 kbps cho video trước overhead. Controller chỉ điều chỉnh trong phạm vi FPS/resolution/quality đã được người dùng chọn, giữ nguyên audio và timeline; đây là đề xuất cần đo, không phải cam kết đạt chính xác hard cap.

### 12.2. Dedupe nội dung, VFR và adaptive

Trước tiên tận dụng metadata/dirty rect và cadence của ScreenCaptureKit. Nếu bổ sung so nội dung, dùng fingerprint/ảnh nhỏ với ngưỡng được kiểm chứng thay vì CPU diff full-resolution mọi frame. Chỉ kiểm tra `.complete` chưa phải dedupe nội dung của riêng app.

Bỏ frame không đổi phải giữ thời gian hiển thị hình trước và audio thật; không cắt bỏ các giây tĩnh khỏi timeline. Bảo đảm ảnh đầu, ảnh khi thay đổi và đoạn cuối. Codec interframe vốn đã có thể nén frame gần giống nhau rất nhỏ nên lợi ích file của dedupe cần đo, đặc biệt nếu thuật toán diff tốn CPU hơn encode hardware.

Dirty rect là metadata về vùng thay đổi, không tự biến AVAssetWriter thành hệ thống ghi các tile độc lập. “Chỉ lưu vùng thay đổi” dạng ảnh/tile là một định dạng/player khác, cần keyframe toàn cảnh định kỳ, manifest và xử lý mất tile; chỉ thử như hướng nâng cao nếu MP4 chuẩn không đạt nhu cầu.

### 12.3. Interframe, GOP và B-frame

Đo GOP theo giây, tránh keyframe quá dày ở <1 FPS; giữ đủ keyframe để seek và rollover. Encoder hiện không có tùy chọn GOP/reorder do app đặt rõ; encoder có thể đã dùng B-frame mặc định, như HEVC trong smoke test. Vì vậy đây là thiếu **điều khiển/kiểm chứng**, không phải bằng chứng app chưa bao giờ dùng B-frame.

VideoToolbox cho phép frame reordering để encode B-frame; có thể thử bật/tắt theo codec. B-frame có thể tăng hiệu quả nén nhưng đi kèm reorder delay/buffer và cần kiểm tra latency ở hình rất thưa. Không cố bật mọi công cụ nén nếu làm audio chờ hoặc tăng RAM quá nhiều. [Apple: AllowFrameReordering](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_allowframereordering).

### 12.4. Audio liên tục, silence và số track

Ưu tiên bitrate phù hợp giọng nói, mono khi hợp lý và tránh track không cần. Nếu trộn mic + system thành một AAC track, mix PCM trước encode giúp tránh lưu hai bản audio rồi export trộn lại. Cần preserve sample alignment và xử lý AEC nếu thực sự cần.

Có thể nghiên cứu VBR/DTX trên backend audio hỗ trợ. Opus có encoder controls cho VBR và DTX, nhưng lựa chọn Opus trong UI hiện không chứng minh CoreAudio path đã expose các controls này; với MP4, code còn fallback về AAC. Cần đánh giá codec/container/player đích, chất lượng âm nhỏ và ASR. [Opus encoder controls](https://opus-codec.org/docs/opus_api-1.5/group__opus__encoderctls.html).

DTX tiết kiệm mã hóa khoảng im lặng không được thực hiện bằng cách xóa đoạn thời gian hoặc ngừng thu nguồn: playback phải giữ đúng chiều dài và không làm mất lời nhỏ. Không thêm silence removal tự động làm thay đổi ca ghi khi yêu cầu là audio liên tục.

### 12.5. Hậu xử lý và quản lý lưu trữ

Remux/streamcopy giữ nguyên encoded payload của track được copy; chỉ đổi container/metadata có thể thay overhead, không nén lại video. Muốn giảm thêm cần bỏ track/phần không cần theo yêu cầu hoặc re-encode với thông số khác. Re-encode tốn thêm CPU/I/O, dung lượng tạm và có thể mất chất lượng; không mặc định áp dụng cho mọi phiên. [FFmpeg: streamcopy và transcoding](https://ffmpeg.org/ffmpeg.html#Streamcopy).

Nén offline nhiều lượt, codec khác hoặc preset encode chậm có thể được thử tại bước export/server để đổi thời gian xử lý lấy hiệu quả nén. Chúng không phải tối ưu CPU realtime tại máy nhân viên. Mỗi bản dẫn xuất cần lý do lưu và chính sách vòng đời để không tăng tổng storage vì giữ cả bản gốc lẫn nhiều bản nén.

Giảm ngày lưu, archive hoặc quota là quản lý tổng dung lượng doanh nghiệp, tách khỏi chất lượng video và không tự động xóa dữ liệu trong recorder. Segment phục vụ finalize/phục hồi; việc chia nhỏ có thể thêm overhead/keyframe. Hardware encoder, queue nhỏ, thumbnail và NV12 chủ yếu tối ưu CPU/RAM; nếu encoded output và bitrate giống nhau thì không thể quy phần giảm RAM thành phần trăm giảm file.

Các thử nghiệm ít ưu tiên hơn gồm grayscale/lọc nhiễu/giảm chi tiết vùng phụ: có thể giảm độ phức tạp nguồn nhưng mất màu/chữ và tăng preprocessing, cần quality-based/VBR hoặc hạ target mới thể hiện thành tiết kiệm file. Chỉ thêm khi workload chứng minh có lợi.

**Thứ tự bổ sung:** thông số cơ bản độc lập + audio thấp và timeline đúng → crop đúng phạm vi → kiểm soát bitrate/budget → dedupe/adaptive → GOP/reorder → audio VBR/DTX và export nâng cao theo backend. Đo lợi ích từng bước, không gọi là “đầy đủ mọi phương pháp” chỉ vì UI có nhiều codec hay preset.
