// Compiles the generated cppwinrt and XAML units that a command-line build
// does not register. XamlTypeInfo.g.cpp also holds wWinMain and the
// InitializeComponent bodies, so the code-behind files do not include the
// .xaml.g.hpp files.
#include "pch.h"

#if __has_include("XamlTypeInfo.g.cpp")
#include "XamlTypeInfo.g.cpp"
#endif
#if __has_include("XamlTypeInfo.Impl.g.cpp")
#include "XamlTypeInfo.Impl.g.cpp"
#endif
#if __has_include("XamlMetaDataProvider.g.h")
#include "XamlMetaDataProvider.g.h"
#endif
#if __has_include("XamlMetaDataProvider.g.cpp")
#include "XamlMetaDataProvider.g.cpp"
#endif
#if __has_include("module.g.cpp")
#include "module.g.cpp"
#endif
