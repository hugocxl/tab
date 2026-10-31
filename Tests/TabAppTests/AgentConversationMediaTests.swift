import AppKit
import WebKit
import XCTest
@testable import TabApp

@MainActor
final class AgentConversationMediaTests: XCTestCase {
    func testActualWKAudioAndVideoMetadataAndSeekingUseScopedRanges() async throws {
        _ = NSApplication.shared
        for (bytes, mime) in [(AgentConversationMediaFixtures.wav, "audio/wav"), (AgentConversationMediaFixtures.mp4, "video/mp4")] {
            var requests: [(UInt64, UInt32)] = []
            let resource = AgentConversationRangedResource(length: UInt64(bytes.count), mimeType: mime, revision: "fixture", read: { offset, length in
                requests.append((offset, length))
                guard offset <= UInt64(bytes.count), UInt64(length) <= UInt64(bytes.count) - offset else { throw NSError(domain: "InvalidRange", code: 1) }
                return bytes.subdata(in: Int(offset)..<Int(offset) + Int(length))
            })
            let preview = try AgentConversationMediaWindow(resource: resource, name: "Muted media fixture")
            defer { preview.close() }
            let deadline = Date().addingTimeInterval(8)
            var ready = false
            while Date() < deadline {
                if let value = try? await preview.webView.evaluateJavaScript("!!document.querySelector('audio,video')"), value as? Bool == true { ready = true; break }
                try await Task.sleep(for: .milliseconds(25))
            }
            guard ready else { XCTFail("The scoped \(mime) preview did not load its media element"); return }
            let result = try await preview.webView.callAsyncJavaScript("""
            const media=document.querySelector('audio,video');media.muted=true;
            const wait=(event,done)=>Promise.race([new Promise((resolve,reject)=>{
              if(done()){resolve();return;}media.addEventListener(event,resolve,{once:true});
              media.addEventListener('error',()=>reject(new Error('Media error '+media.error?.code)),{once:true});
            }),new Promise((_,reject)=>setTimeout(()=>reject(new Error('Timed out waiting for '+event)),6000))]);
            await wait('loadedmetadata',()=>media.readyState>=1);
            const duration=media.duration;media.currentTime=0.75;
            await wait('seeked',()=>!media.seeking&&Math.abs(media.currentTime-0.75)<0.05);
            return {duration,time:media.currentTime,seeking:media.seeking,muted:media.muted};
            """, arguments: [:], in: nil, contentWorld: .page)
            let values = try XCTUnwrap(result as? [String: Any])
            XCTAssertEqual(values["duration"] as? Double ?? 0, 2, accuracy: 0.05, mime)
            XCTAssertEqual(values["time"] as? Double ?? 0, 0.75, accuracy: 0.05, mime)
            XCTAssertEqual(values["muted"] as? Bool, true)
            XCTAssertEqual(values["seeking"] as? Bool, false)
            XCTAssertFalse(requests.isEmpty)
            XCTAssertTrue(requests.allSatisfy { $0.1 <= AgentConversationRangedResource.chunkSize })
            if mime == "video/mp4" { XCTAssertTrue(requests.contains { $0.0 > 0 }, "WK must request independently addressed MP4 ranges") }
            XCTAssertEqual(preview.webView.configuration.userContentController.userScripts.count, 0)
        }
    }
}
