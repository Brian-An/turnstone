# Minimal Liquid Glass interface

Use native Liquid Glass for the radial wheel and primary interface controls on macOS 26 and later.
Use standard translucent materials and bordered controls on macOS 13 through 15.
Retain system support for dark appearance, reduced transparency, increased contrast, and reduced motion.

The wheel keeps its existing geometry, hit testing, keyboard navigation, drop destination, and accessibility elements.
Replace the opaque painted background with separated glass petals and a small glass center.
Reserve orange for the selected petal and primary action.
Keep the shortcut legend small and secondary.

Make the welcome window compact, with one app heading, a wheel preview, a short instruction, and Choose Files.
Use translucent window backgrounds, quiet typography, and fewer borders and repeated headings.
Keep editor content readable and apply glass to controls rather than covering photos or documents with translucent effects.
Flatten recent-job cards into a simple list and keep all existing actions and settings accessible.

Build with the current Apple SDK while retaining the macOS 13 deployment target through availability checks.
Verify the updated app with the existing conversion suite and native UI checks for the wheel, conversion, editor, settings, and floating shelf.
