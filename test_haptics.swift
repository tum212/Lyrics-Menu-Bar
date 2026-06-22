import AppKit

print("Will vibrate in 3 seconds. Put your finger on the trackpad and switch to another app!")
sleep(3)
print("Vibrating!")
NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
print("Done.")
