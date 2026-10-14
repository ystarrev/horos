#pragma once

// C bridge keeps the DICOM server independent of Objective-C and Swift headers.
#ifdef __cplusplus
extern "C" {
#endif
void *HorosBeginActivity(void);
void HorosEndActivity(void *token);
#ifdef __cplusplus
}

class HorosActivityScope final {
public:
    HorosActivityScope() : token_(HorosBeginActivity()) {}
    ~HorosActivityScope() { HorosEndActivity(token_); }
    HorosActivityScope(const HorosActivityScope&) = delete;
    HorosActivityScope& operator=(const HorosActivityScope&) = delete;
private:
    void *token_;
};
#endif
