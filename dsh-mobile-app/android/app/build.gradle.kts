import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // 闁哄嫭鍎崇槐鈩冩償閺冨倹鏆?Kotlin闁挎稑婢僥ttings 鐎瑰憡褰冮敍鎰板及?2.4.0闁挎稑顧€缁变即宕樺畡鐗堝剻闁告柣鍔岃ぐ鏌ユ閻欏懐绀夊☉鎾崇С缁堕鎸?Flutter 闁圭粯甯婂▎銏ゅ礉閵婏腹鍋撴担鍝ュ畨闁?
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release 缂佹稒鍎抽幃鏇㈡晬濮樻剚鍤㈤柛?android/key.properties闁挎稑娼沬tignore闁挎稑鐭侀～鍡涘冀?.gitignore闁挎稑顦埀?
// 闁?key.properties 闁哄啳娉涘ú鏍焻閳?debug 缂佹稒鍎抽幃鏇㈡晬鐏炶偐绠介悹鍥︾閸忛亶宕欓埀顒勫礂鐎ｎ喗鐣峰☉鏃傚枙閸忔﹢寮搁崟顐ょ处闁?
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.dsh.remote"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications闁挎稑娼焥sue #46闁挎稑顦抽々锕€效閸屾氨纾婚柛?core library desugaring
        isCoreLibraryDesugaringEnabled = true
    }

    // 閻庡湱濮锋晶鍧楀礉閵娧勬毎 WebP 濞戞挸绉寸敮鍥╃磽閳哄绐楅弶鈺傚姌椤㈡垿寮崜浣圭函闁?mmap/婵炵繝绀佺槐锛勬喆閿濆洨鍨抽柨娑樼焸娴尖晠宕楀鍡欐Ж婵炲棌鈧櫕鍎欓柛鏂诲姀琚欓柛?14MB 缂佽京濮靛妤呭Υ?
    androidResources {
        noCompress += "webp"
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.dsh.remote"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // 閹煎瓨姊婚弫銈夊触瀹ュ牐娉查柛妤冨С缂嶅懐绮敂鑲╃dev 闁告牕鎳庤ぐ褔妫侀埀顒勫捶?gradle 闂佹彃鐭侀々顐︽儎閺嶎剛绠瑰☉鎿冧簻瀹曠増鎷呭鍥跺剨闁告鍟胯ぐ鏌ュ绩閻熺増鍊抽柨?
        // 濞戞挸绉寸换鈧柛鎰Х椤斺偓闁哄瀚紓鎾绘嚇濮橆厽鎷遍梺鎻掔Т閸?AndroidManifest.xml闁挎稑婢?.3.3 閻犲洤瀚鎼佸极濞嗘帩鍞查柨?
        // 闁煎瓨纰嶅﹢浼村绩閻熸澘鏅告繛鎾虫噹瀹曠喖宕?閺夆晜锚鐢?闁哄洨鍋撴俊?KeepAliveService 闁汇劌瀚敍鎰板及鎼淬劍楗娑櫳戞慨浠嬪箳婢舵稓绀嗛柕?
        manifestPlaceholders["appName"] = "DSH Remote"
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                // storeFile 闁烩晝顭堥?android/ 濡炪倕婀卞ú浼村冀閻у摜绀刱ey.properties 闂佹彃鑻崯?app/dsh-release.jks闁?
                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                // 闁哄啰濮甸婊冾嚕韫囨洦鍔柛姘У濡炲倿宕堕悙琛″亾閳?debug 缂佹稒鍎抽幃鏇㈡晬閸粎鐭岄梻鍕姌閸ゆ粓鎮?婵炴潙顑堥惁顖炲礆閸℃绲洪柨?
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // flutter_local_notifications 濞撴碍绻嗙粋鍡涙儍?Java 8+ API 闁肩浜涵鎼佸绩椤栨稑鐦?
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    // 闁诡噮鍓氱拠鐐烘偠閸愵喗妗ㄩ柡澶嬪鑶╅柛?seam 闁汇劌瀚崙?JVM 闁告娲樼粊鎾晬閸︾灚agePanelModelTest闁挎稑顧€缁?
    // org.json 闁?Android 濞?JVM 闁告艾鐭侀～澶愭嚑閸愯法绀夋繛鏉戭儓閻︻垳鐚鹃弰蹇曠唴鐎垫澘瀚畷鐔兼偑椤掆偓缁扁晠宕楅妷銉ョギ闁告瑯鍨埀?
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}

