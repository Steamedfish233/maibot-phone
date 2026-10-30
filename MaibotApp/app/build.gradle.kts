import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.maibot.app"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.maibot.app"
        minSdk = 24
        targetSdk = 34
        versionCode = 31
        versionName = "2.0.3"
    }

    // The repo ships no keystore and no passwords: *.jks and keystore.properties are gitignored.
    // Put maibot.jks + keystore.properties next to this module to sign locally; without them
    // Gradle produces an unsigned release APK instead of failing.
    val keystoreFile = rootProject.file("maibot.jks")
    val keystorePropsFile = rootProject.file("keystore.properties")
    val keystoreProps = Properties().apply {
        if (keystorePropsFile.exists()) keystorePropsFile.inputStream().use { load(it) }
    }
    val storePasswordValue = System.getenv("MAIBOT_KEYSTORE_PASSWORD")
        ?: keystoreProps.getProperty("storePassword")
    val keyPasswordValue = System.getenv("MAIBOT_KEY_PASSWORD")
        ?: keystoreProps.getProperty("keyPassword")
    val keyAliasValue = System.getenv("MAIBOT_KEY_ALIAS")
        ?: keystoreProps.getProperty("keyAlias")
        ?: "maibot"
    val canSign = keystoreFile.exists() && !storePasswordValue.isNullOrBlank()

    signingConfigs {
        create("release") {
            if (canSign) {
                storeFile = keystoreFile
                storePassword = storePasswordValue
                keyAlias = keyAliasValue
                keyPassword = keyPasswordValue ?: storePasswordValue
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = if (canSign) signingConfigs.getByName("release") else null
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("com.google.android.material:material:1.9.0")
}
