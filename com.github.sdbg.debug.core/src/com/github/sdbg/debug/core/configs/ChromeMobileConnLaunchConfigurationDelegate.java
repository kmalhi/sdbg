/*
 * Copyright (c) 2013, the Dart project authors.
 * 
 * Licensed under the Eclipse Public License v1.0 (the "License"); you may not use this file except
 * in compliance with the License. You may obtain a copy of the License at
 * 
 * http://www.eclipse.org/legal/epl-v10.html
 * 
 * Unless required by applicable law or agreed to in writing, software distributed under the License
 * is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
 * or implied. See the License for the specific language governing permissions and limitations under
 * the License.
 */

package com.github.sdbg.debug.core.configs;

import com.github.sdbg.debug.core.SDBGDebugCorePlugin;
import com.github.sdbg.debug.core.SDBGLaunchConfigWrapper;
import com.github.sdbg.debug.core.SDBGLaunchConfigurationDelegate;
import com.github.sdbg.debug.core.internal.util.BrowserManager;
import com.github.sdbg.debug.core.internal.util.IDFilterDeviceChooser;
import com.github.sdbg.debug.core.internal.util.LaunchConfigResourceResolver;
import com.github.sdbg.debug.core.internal.util.URLFilterTabChooser;
import com.github.sdbg.debug.core.util.IDeviceChooser;
import com.github.sdbg.utilities.instrumentation.InstrumentationBuilder;

import org.eclipse.core.runtime.CoreException;
import org.eclipse.core.runtime.IConfigurationElement;
import org.eclipse.core.runtime.IExtensionPoint;
import org.eclipse.core.runtime.IProgressMonitor;
import org.eclipse.core.runtime.Platform;
import org.eclipse.debug.core.ILaunch;
import org.eclipse.debug.core.ILaunchConfiguration;
import org.eclipse.debug.core.ILaunchManager;

/**
 * A ILaunchConfigurationDelegate implementation that can connect to a running Chrome for Mobile
 * instance.
 */
public class ChromeMobileConnLaunchConfigurationDelegate extends SDBGLaunchConfigurationDelegate {
  private static IDeviceChooser uiDeviceChooser;

  private static synchronized IDeviceChooser getUIDeviceChooser() {
    if (uiDeviceChooser == null) {
      IExtensionPoint extensionPoint = Platform.getExtensionRegistry().getExtensionPoint(
          "com.github.sdbg.debug.core.uiDeviceChooser");
      for (IConfigurationElement element : extensionPoint.getConfigurationElements()) {
        try {
          uiDeviceChooser = (IDeviceChooser) element.createExecutableExtension("class");
          break;
        } catch (CoreException e) {
          SDBGDebugCorePlugin.logError(e);
        }
      }
    }

    return uiDeviceChooser;
  }

  /**
   * Create a new ChromeConnLaunchConfigurationDelegate.
   */
  public ChromeMobileConnLaunchConfigurationDelegate() {
  }

  @Override
  public void doLaunch(ILaunchConfiguration configuration, String mode, ILaunch launch,
      IProgressMonitor monitor, InstrumentationBuilder instrumentation) throws CoreException {
    if (!ILaunchManager.DEBUG_MODE.equals(mode)) {
      throw new CoreException(SDBGDebugCorePlugin.createErrorStatus("Execution mode '" + mode
          + "' is not supported."));
    }

    SDBGLaunchConfigWrapper launchConfig = new SDBGLaunchConfigWrapper(configuration);

    BrowserManager browserManager = new BrowserManager(null);
    browserManager.connect(
        launch,
        configuration,
        new LaunchConfigResourceResolver(launchConfig),
        new IDFilterDeviceChooser(launchConfig.getDevice(), getUIDeviceChooser()),
        new URLFilterTabChooser(launchConfig.getUrl(), getUIBrowserTabChooser()),
        monitor);
  }
}
