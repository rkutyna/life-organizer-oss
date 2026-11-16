import { QueryClientProvider } from "@tanstack/react-query";
import { BrowserRouter, Route, Routes } from "react-router";

import { Toaster } from "@/components/ui/sonner";
import { TooltipProvider } from "@/components/ui/tooltip";

import { useAuthState } from "./auth";
import { AuthPending, LoginScreen, SetupScreen } from "./AuthScreens";
import { MODULES } from "./modules";
import { NotFound } from "./NotFound";
import { queryClient } from "./queryClient";
import { Shell } from "./Shell";
import { ThemeProvider } from "./theme";

/** Providers, then the auth gate. */
export function App() {
  return (
    <ThemeProvider>
      <QueryClientProvider client={queryClient}>
        <TooltipProvider delayDuration={300}>
          <AuthGate />
          <Toaster position="bottom-right" />
        </TooltipProvider>
      </QueryClientProvider>
    </ThemeProvider>
  );
}

/** Setup on a fresh install, login without a session, else the app. */
function AuthGate() {
  const auth = useAuthState();
  if (!auth.data) {
    return auth.isError ? (
      <AuthPending error={auth.error.message} onRetry={() => void auth.refetch()} />
    ) : (
      <AuthPending />
    );
  }
  if (auth.data.setup_required) return <SetupScreen />;
  if (!auth.data.authenticated) return <LoginScreen displayName={auth.data.display_name} />;
  return <AppRoutes />;
}

/** One route per registered module (see src/app/modules.ts). */
function AppRoutes() {
  return (
    <BrowserRouter>
      <Routes>
        <Route element={<Shell />}>
          {MODULES.map(({ key, path, page: Page }) =>
            path === "/" ? (
              <Route key={key} index element={<Page />} />
            ) : (
              <Route key={key} path={`${path.replace(/^\//, "")}/*`} element={<Page />} />
            ),
          )}
          <Route path="*" element={<NotFound />} />
        </Route>
      </Routes>
    </BrowserRouter>
  );
}
