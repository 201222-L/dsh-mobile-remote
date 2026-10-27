package com.dsh.remote

/** 宠物文案：状态、互动、面板标签。双语与 App 设置里的语言开关一致。 */
object PetCopy {
    fun status(state: String, activity: String?, lang: String): String {
        val en = lang == "en"
        return when (state) {
            "IDLE" -> if (en) "I'm here, waiting for a new task" else "我在这儿等新任务哦"
            "THINKING" -> if (en) "Thinking about the next step" else "正在认真想下一步呢"
            "WORKING" -> when (activity) {
                "searching" -> if (en) "Looking for the right files" else "正在帮你找相关内容呢"
                "editing" -> if (en) "Editing this part" else "这部分正在修改中哦"
                "testing" -> if (en) "Running checks" else "正在认真检查结果呢"
                "commanding" -> if (en) "Running a project command" else "正在执行项目命令呢"
                else -> if (en) "Still working on it" else "正在继续处理任务呢"
            }
            "WAITING" -> if (en) "Waiting for your confirmation" else "需要你确认一下后续呢"
            "SUCCESS" -> if (en) "Task completed" else "这次的任务搞定啦~"
            "ERROR" -> if (en) "Something went wrong" else "任务好像遇到一点问题呢"
            "DISCONNECTED" -> if (en) "Disconnected from the desktop" else "和电脑的连接断开啦"
            else -> if (en) "I'm here" else "我在这儿呢"
        }
    }

    fun interaction(clip: String, doubleTap: Boolean, lang: String): String {
        val en = lang == "en"
        return when (clip) {
            "head_pat" -> if (doubleTap) {
                if (en) "Okay, okay, I know you like me~" else "好啦好啦，知道你喜欢我~"
            } else {
                if (en) "Head pats won't make me work less~" else "摸摸也不能让我少干活哦~"
            }
            "tail" -> if (en) "My tail is not a progress bar!" else "尾巴不是进度条啦！"
            "poke" -> if (en) "Why poke me? The task is still running" else "戳我干嘛，任务还在跑呢"
            "dragging" -> if (en) "Where are we going?" else "要带我去哪儿呀？"
            else -> if (en) "Hi~" else "在呢~"
        }
    }

    fun stateLabel(state: String, lang: String): String {
        val en = lang == "en"
        return when (state) {
            "IDLE" -> if (en) "Idle" else "空闲"
            "THINKING" -> if (en) "Thinking" else "思考中"
            "WORKING" -> if (en) "Working" else "处理中"
            "WAITING" -> if (en) "Needs you" else "待确认"
            "SUCCESS" -> if (en) "Done" else "完成"
            "ERROR" -> if (en) "Error" else "出错"
            "DISCONNECTED" -> if (en) "Offline" else "已断开"
            else -> if (en) "Idle" else "空闲"
        }
    }

    fun notification(kind: String?, lang: String): String {
        val en = lang == "en"
        return when (kind) {
            "completed" -> if (en) "Task done" else "任务完成"
            "failed" -> if (en) "Task failed" else "任务失败"
            "needs-answer" -> if (en) "Your input needed" else "需要你回答"
            else -> if (en) "Notification" else "通知"
        }
    }

    fun onboarding(lang: String): String =
        if (lang == "en") {
            "Tap me · Long-press for panel · Drag to the edge to hide"
        } else {
            "点我互动 · 长按打开面板 · 拖到边缘会躲起来"
        }

    fun waitingDetail(lang: String): String =
        if (lang == "en") "DSH · waiting for the next task" else "DSH · 等待下一次任务"
}
