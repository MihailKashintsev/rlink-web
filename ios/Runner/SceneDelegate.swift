import Flutter
import GoogleSignIn
import UIKit

/// После миграции Flutter на UISceneDelegate методы `AppDelegate.application(_:open:options:)`
/// системой не вызываются — URL-контексты приходят в сцену. `FlutterSceneDelegate` форвардит их
/// в плагины, принявшие `FlutterSceneLifeCycleDelegate`, но `google_sign_in_ios` 5.9.0 ещё
/// сидит на старом `FlutterPlugin.application(_:open:options:)` — и без явного bridge его
/// URL-callback не срабатывает.
///
/// Дополнительно: плагин читает `UIApplication.shared.keyWindow.rootViewController` для выбора
/// presenter-контроллера. В сценах `keyWindow` иногда возвращает nil до `makeKeyAndVisible`, и тогда
/// `GIDSignIn.signInWithPresentingViewController:` не открывает диалог. Явный `makeKeyAndVisible`
/// гарантирует, что для плагинов-старожилов окно найдётся.
class SceneDelegate: FlutterSceneDelegate {

    override func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        super.scene(scene, willConnectTo: session, options: connectionOptions)
        // `UIApplication.keyWindow` должен возвращать окно сцены для плагинов на старом API
        // (google_sign_in_ios и ко.) — без этого экран входа в Google просто не показывается.
        DispatchQueue.main.async {
            if let window = self.window, !window.isKeyWindow {
                window.makeKeyAndVisible()
            }
        }
    }

    override func scene(
        _ scene: UIScene,
        openURLContexts URLContexts: Set<UIOpenURLContext>
    ) {
        super.scene(scene, openURLContexts: URLContexts)
        for ctx in URLContexts {
            // Диск / OAuth callback в явном виде — если вдруг GIDSignIn использует URL-схему.
            if GIDSignIn.sharedInstance.handle(ctx.url) {
                continue
            }
            // Fallback: дернуть AppDelegate-плагины, не мигрировавшие на scene lifecycle
            // (через openURL AppDelegate их `application(_:open:options:)` получает вызов).
            var options: [UIApplication.OpenURLOptionsKey: Any] = [:]
            if let src = ctx.options.sourceApplication {
                options[.sourceApplication] = src
            }
            if let ann = ctx.options.annotation {
                options[.annotation] = ann
            }
            _ = UIApplication.shared.delegate?.application?(
                UIApplication.shared,
                open: ctx.url,
                options: options
            )
        }
    }
}
