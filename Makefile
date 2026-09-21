.PHONY: build runtime test clean

build:: runtime
	swift build -c release
	cp -f .build/release/wechattweak ./wechattweak
	cp -R .build/release/WeChatTweak_WeChatTweak.bundle ./
	cp -f .build/runtime/libWeChatTweak.dylib ./libWeChatTweak.dylib
	cp -f .build/runtime/Dobby-LICENSE ./Dobby-LICENSE

runtime:
	cmake -S Runtime -B .build/runtime -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_POLICY_VERSION_MINIMUM=3.5
	cmake --build .build/runtime --target WeChatTweak -j 4

test: runtime
	swift test
	cmake --build .build/runtime --target RuntimeTests -j 4
	.build/runtime/RuntimeTests

clean::
	rm -rf .build
	rm -f wechattweak
	rm -f libWeChatTweak.dylib
	rm -rf WeChatTweak_WeChatTweak.bundle
	rm -f Dobby-LICENSE
