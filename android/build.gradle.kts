allprojects {
    repositories {
        maven { url = uri("https://repo.huaweicloud.com/repository/maven") }
        google()
        mavenCentral()
        maven { url = uri("https://storage.flutter-io.cn/download.flutter.io") }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// ---------------------------------------------------------------------------
// 平台健康检查（本机构建环境修复）：
// 本机 SDK 的 platforms/android-34 残缺（缺少 core-for-system-modules.jar），
// 而部分插件（如 file_picker）硬编码 compileSdk 34，会使 AGP 9 的
// androidJdkImage provider 求值为空，报 "Cannot query the value of this
// provider" 并导致构建失败。这里在每个插件库项目评估完成后检查其请求的
// 平台是否完整，不完整时自动改用最近的完整平台（健康的平台不受影响）。
// ---------------------------------------------------------------------------
subprojects {
    // 上面的 evaluationDependsOn(":app") 可能让 :app 提前完成评估，
    // 对已评估的项目不能再注册 afterEvaluate。
    if (state.executed) return@subprojects
    afterEvaluate {
        if (!plugins.hasPlugin("com.android.library")) return@afterEvaluate
        val androidExt = extensions.findByName("android") ?: return@afterEvaluate

        val sdkDir: java.io.File = run {
            val props = java.util.Properties()
            val f = rootProject.file("local.properties")
            if (f.exists()) f.inputStream().use { props.load(it) }
            val dir = props.getProperty("sdk.dir")
                ?: System.getenv("ANDROID_SDK_ROOT")
                ?: System.getenv("ANDROID_HOME")
            dir?.let { java.io.File(it) }
        } ?: return@afterEvaluate

        fun platformHealthy(api: Int): Boolean =
            listOf("android-$api", "android-$api.0").any {
                java.io.File(sdkDir, "platforms/$it/core-for-system-modules.jar").exists()
            }

        val cls = androidExt.javaClass
        val currentApi: Int = run {
            val g = cls.methods.firstOrNull { it.name == "getCompileSdk" && it.parameterCount == 0 }
            val v = g?.invoke(androidExt) as? Int
            if (v != null) return@run v
            val g2 = cls.methods.firstOrNull { it.name == "getCompileSdkVersion" && it.parameterCount == 0 }
            val s = g2?.invoke(androidExt) as? String
            s?.filter { ch -> ch.isDigit() }?.toIntOrNull()
        } ?: return@afterEvaluate

        if (platformHealthy(currentApi)) return@afterEvaluate

        // 找出本机所有「完整」的平台
        val platformsDir = java.io.File(sdkDir, "platforms")
        val healthyApis = (platformsDir.listFiles() ?: emptyArray())
            .filter { it.isDirectory && it.name.startsWith("android-") }
            .mapNotNull { it.name.removePrefix("android-").substringBefore('.').toIntOrNull() }
            .filter { platformHealthy(it) }
            .distinct()
        if (healthyApis.isEmpty()) return@afterEvaluate

        // 优先对齐 :app 的 flutter.compileSdkVersion：其它 Flutter 插件用的就是它，
        // 且 AGP 要求依赖方 compileSdk 不低于被依赖库。
        val flutterCompileSdk: Int? = run {
            val ext = rootProject.project(":app").extensions.findByName("flutter")
                ?: return@run null
            val g = ext.javaClass.methods.firstOrNull {
                it.name == "getCompileSdkVersion" && it.parameterCount == 0
            }
            when (val v = g?.invoke(ext)) {
                is Int -> v
                is String -> v.filter { ch -> ch.isDigit() }.toIntOrNull()
                else -> null
            }
        }
        val targetApi = when {
            flutterCompileSdk != null && platformHealthy(flutterCompileSdk) ->
                flutterCompileSdk
            else ->
                healthyApis.filter { it >= currentApi }.maxOrNull() ?: healthyApis.max()
        }

        // 兼容新旧 DSL 的 compileSdk 设置
        val setter = cls.methods.firstOrNull { it.name == "setCompileSdk" && it.parameterCount == 1 }
        if (setter != null) {
            setter.invoke(androidExt, targetApi)
        } else {
            val m2 = cls.methods.firstOrNull {
                it.name == "compileSdkVersion" && it.parameterCount == 1 &&
                    it.parameterTypes[0] == Integer.TYPE
            }
            if (m2 != null) {
                m2.invoke(androidExt, targetApi)
            } else {
                val m3 = cls.methods.firstOrNull {
                    it.name == "compileSdkVersion" && it.parameterCount == 2
                }
                m3?.invoke(androidExt, targetApi, null)
            }
        }
        logger.lifecycle(
            "LiteTavern: project '$name' requested compileSdk $currentApi " +
                "(platform incomplete), remapped to $targetApi"
        )
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
